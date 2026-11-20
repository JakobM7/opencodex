import { expect, test } from "bun:test";
import { deriveProviderPresets, enrichProviderFromRegistry } from "../../src/providers/derive";
import { providerMatchesRegistryTransport, registryEntryForProviderDestination } from "../../src/providers/registry";
import { deepseekReasoningMapFor } from "../../src/providers/registry/model-seeds";
import { captureRouteStaticPolicy, routeModel, routedProviderConfig } from "../../src/router";
import type { OcxConfig, OcxProviderConfig } from "../../src/types";

test("a metadata alias on another adapter does not grant registry transport ownership", () => {
  // Volcengine's canonical row moved to Responses; saved Chat rows remain Chat.
  const provider: OcxProviderConfig = {
    adapter: "openai-chat", authMode: "key", apiKey: "test-key",
    baseUrl: "https://ark.cn-beijing.volces.com/api/coding/v3",
  };
  expect(registryEntryForProviderDestination(provider)?.id).toBe("volcengine-coding-plan");
  expect(providerMatchesRegistryTransport("volcengine-coding-plan", provider)).toBe(false);
  expect(routedProviderConfig("volcengine-coding-plan", provider).adapter).toBe("openai-chat");
  expect(captureRouteStaticPolicy("volcengine-coding-plan", "doubao-seed-2.0-code", provider).provider.adapter).toBe("openai-chat");
});

test("the Go inference alias identifies renamed destinations while the preset remains pinned", () => {
  const provider: OcxProviderConfig = {
    adapter: "openai-chat", authMode: "key", apiKey: "test-key",
    baseUrl: "https://opencode.ai/inference/go/v1",
  };
  expect(registryEntryForProviderDestination(provider)?.id).toBe("opencode-go");
  expect(providerMatchesRegistryTransport("opencode-go", provider)).toBe(true);
  expect(routedProviderConfig("opencode-go", provider).baseUrl).toBe("https://opencode.ai/zen/go/v1");
  expect(routedProviderConfig("renamed-go", provider).baseUrl).toBe(provider.baseUrl);
});

test("non-Alibaba destination aliases fill effort defaults and maps while operator values win", () => {
  // Z.AI's former Chat address carries the GLM-5.3 default; Ark's Chat alias carries a map.
  const zaiUrl = "https://api.z.ai/api/coding/paas/v4";
  const arkUrl = "https://ark.cn-beijing.volces.com/api/coding/v3";
  const registryMap = deepseekReasoningMapFor("deepseek-v4-flash");
  const zai: OcxProviderConfig = { adapter: "openai-chat", baseUrl: zaiUrl };
  const ark: OcxProviderConfig = { adapter: "openai-chat", baseUrl: arkUrl };
  enrichProviderFromRegistry("GLM", zai);
  enrichProviderFromRegistry("ark-chat", ark);
  expect(zai.modelDefaultReasoningEfforts?.["glm-5.3"]).toBe("max");
  expect(ark.modelReasoningEffortMap?.["deepseek-v4-flash"]).toEqual(registryMap);
  expect(routedProviderConfig("GLM", { adapter: "openai-chat", baseUrl: zaiUrl })
    .modelDefaultReasoningEfforts?.["glm-5.3"]).toBe("max");
  expect(routedProviderConfig("ark-chat", { adapter: "openai-chat", baseUrl: arkUrl })
    .modelReasoningEffortMap?.["deepseek-v4-flash"]).toEqual(registryMap);

  const zaiOperator: OcxProviderConfig = {
    adapter: "openai-chat", baseUrl: zaiUrl, modelDefaultReasoningEfforts: { "glm-5.3": "low" },
  };
  const arkOperator: OcxProviderConfig = {
    adapter: "openai-chat", baseUrl: arkUrl, modelReasoningEffortMap: { "deepseek-v4-flash": { medium: "low" } },
  };
  const zaiRouted = routedProviderConfig("GLM", zaiOperator);
  const arkRouted = routedProviderConfig("ark-chat", arkOperator);
  enrichProviderFromRegistry("GLM", zaiOperator);
  enrichProviderFromRegistry("ark-chat", arkOperator);
  for (const row of [zaiOperator, zaiRouted]) {
    expect(row.modelDefaultReasoningEfforts?.["glm-5.3"]).toBe("low");
    expect(row.modelDefaultReasoningEfforts?.["glm-5.3-flash"]).toBe("max");
  }
  for (const row of [arkOperator, arkRouted]) {
    expect(row.modelReasoningEffortMap?.["deepseek-v4-flash"]).toEqual({ ...registryMap, medium: "low" });
  }
});

test("Neuralwatt honors either configured OpenAI wire without unlocking unrelated presets", () => {
  const model = "deepseek-v4.1-flash";
  const chat: OcxProviderConfig = { adapter: "openai-chat", baseUrl: "https://api.neuralwatt.com/v1" };
  const responses = { ...chat, adapter: "openai-responses" };
  const routed = routedProviderConfig("neuralwatt", responses);
  expect(routed.adapter).toBe("openai-responses");
  expect(deriveProviderPresets().find(entry => entry.id === "neuralwatt")?.adapterChoices)
    .toEqual(["openai-chat", "openai-responses"]);
  expect(routedProviderConfig("neuralwatt", chat).adapter).toBe("openai-chat");
  expect(routedProviderConfig("neuralwatt", { ...responses, adapter: "anthropic" }).adapter).toBe("openai-chat");
  expect(routedProviderConfig("groq", { ...responses, baseUrl: "https://api.groq.com/openai/v1" }).adapter).toBe("openai-chat");
  const config: OcxConfig = { port: 10100, providers: { neuralwatt: responses } };
  expect(routeModel(config, `neuralwatt/${model}`).provider.adapter).toBe("openai-responses");
  config.providers.neuralwatt = { ...responses, modelAdapters: { [model]: "openai-chat" } };
  expect(routeModel(config, `neuralwatt/${model}`).staticPolicy.model.adapter).toBe("openai-chat");
});
