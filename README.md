# xbox_receiver

A Rust program that turns your Windows PC into a virtual Xbox 360 controller, driven by UDP packets from another machine.

## Install

1. Install the **ViGEmBus driver** (provides the virtual controller).
   - Download the latest MSI from https://github.com/nefarius/ViGEmBus/releases
   - Run the installer, then reboot.
2. Install the **Rust toolchain** (1.70 or newer) from https://rustup.rs
3. Build the program:
   ```powershell
   cargo build --release
   ```

## Usage

1. Run the program:
   ```powershell
   .\target\release\xbox_receiver.exe
   ```
2. You should see:
   ```
   Virtual Xbox Controller created successfully.
   Listening for UDP packets on port 9001...
   ```
3. From your sender machine, send UDP packets to **port 9001** of this PC. The game will now see a standard Xbox 360 controller.
4. Press `Ctrl+C` to stop. The virtual controller is removed automatically.
