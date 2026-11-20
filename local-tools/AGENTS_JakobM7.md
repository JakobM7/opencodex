# JakobM7's OpenCodex development instructions

- Make routine changes on the fork's `dev` branch. Use a temporary worktree when isolation is useful.
- After verification, merge completed work from temporary worktrees back into the fork's `dev` branch.
- For an upstream contribution, create a PR branch from `upstream/dev` and cherry-pick the relevant commits. Review `git diff upstream/dev...HEAD` before opening the PR.
- Stable listens on `127.0.0.1:10100`. The source checkout on `dev` listens on `127.0.0.1:10101` with its own `OPENCODEX_HOME`. Keep the installed proxy running during development.
- Start an individual CLI session using `OpenCodex-Client.bat` and select its proxy in the menu. The launcher assumes both clients are available on PATH and the selected proxy is already running.
- Run the launcher from your project directory to give the selected client that working directory. The launcher scopes its routing override to the selected session.
- Keep API keys, OAuth stores and runtime state outside Git.
