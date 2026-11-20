# JakobM7's OpenCodex development instructions

- Keep personal launchers and instructions on `jakob/local-tools` in `JakobM7/opencodex`. Start upstream pull requests from a branch based on upstream `dev`.
- Stable listens on `127.0.0.1:10100`. The source checkout on `dev` listens on `127.0.0.1:10101` with its own `OPENCODEX_HOME`. Keep the installed proxy running during development.
- Start an individual CLI session using `OpenCodex-Client.bat` and select its proxy in the menu. The launcher assumes both clients are available on PATH and the selected proxy is already running.
- Run the launcher from your project directory to give the selected client that working directory. The launcher scopes its routing override to the selected session.
- Keep API keys, OAuth stores and runtime state outside Git.
