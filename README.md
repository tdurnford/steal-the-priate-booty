# Roblox Game Template

A production-grade Roblox game template with batteries included:

- **Knit** framework (client controllers + server services)
- **Fusion** UI library with theming system
- **ProfileService** data persistence wrapper
- **Rojo** filesystem-first workflow
- **Selene** linting + **StyLua** formatting
- **GitHub Actions** CI pipeline
- **Rokit** toolchain pinning

## Quick Start

### 1. Install tools

```bash
# Install Rokit: https://github.com/rojo-rbx/rokit
rokit install
```

### 2. Install packages

```bash
wally install
```

### 3. Start Rojo

```bash
make serve
```

In Roblox Studio, install the Rojo plugin and click **Connect**.

### 4. Lint / format / build

```bash
make lint
make format
make build
```

## Repo Layout

```
src/
  client/                        # StarterPlayerScripts
    Controllers/
      ExampleController.lua      # Sample Knit controller
      SoundController.lua        # Generic 2D/3D sound playback
      NotificationController.lua # Toast-style notification system
    UI/
      UITheme.lua                # Centralized theme (colors, fonts, etc.)
      SettingsPanel.lua          # Player settings toggles (Fusion)
    Main.client.lua              # Auto-discovers controllers, starts Knit
  server/                        # ServerScriptService
    Services/
      ExampleService.lua         # Sample Knit service
      DataService.lua            # ProfileService wrapper (load/save/signals)
    Main.server.lua              # Auto-discovers services, starts Knit
  shared/                        # ReplicatedStorage/Shared
    Types.lua                    # PlayerData + Settings type definitions
    Util.lua                     # Generic utilities (formatNumber, clamp, etc.)
assets/                          # Non-code assets
places/                          # Base place file (.rbxlx)
scripts/                         # Build, lint, format, test scripts
```

## Included Infrastructure

| Feature | Files |
|---------|-------|
| Knit framework | `Main.client.lua`, `Main.server.lua`, Example* |
| Player data (ProfileService) | `DataService.lua`, `Types.lua` |
| UI theming | `UITheme.lua` (client + shared) |
| Settings panel (Fusion) | `SettingsPanel.lua` |
| Sound system | `SoundController.lua` |
| Notifications | `NotificationController.lua` |
| CI pipeline | `.github/workflows/ci.yml` |

## License

MIT - see [LICENSE](LICENSE).
