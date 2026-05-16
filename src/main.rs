use std::net::UdpSocket;
use std::sync::{Arc, Mutex};
use std::net::SocketAddr;
// Use the new vigem-rust crate that supports rumble notifications
use vigem_rust::{Client, X360Report, X360Button};

/// Represents the physical state of the controller received via UDP.
/// Must match the exact layout of the sender's ControllerState.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct ControllerState {
    pub left_x: i16,
    pub left_y: i16,
    pub right_x: i16,
    pub right_y: i16,
    pub left_trigger: u8,
    pub right_trigger: u8,
    pub buttons: u16,
}

// Bitmasks for controller buttons
const BTN_A: u16 = 1 << 0;
const BTN_B: u16 = 1 << 1;
const BTN_X: u16 = 1 << 2;
const BTN_Y: u16 = 1 << 3;
const BTN_UP: u16 = 1 << 4;
const BTN_DOWN: u16 = 1 << 5;
const BTN_LEFT: u16 = 1 << 6;
const BTN_RIGHT: u16 = 1 << 7;
const BTN_LB: u16 = 1 << 8;
const BTN_RB: u16 = 1 << 9;
const BTN_LS: u16 = 1 << 10;
const BTN_RS: u16 = 1 << 11;
const BTN_START: u16 = 1 << 12;
const BTN_SELECT: u16 = 1 << 13;

fn main() {
    // 1. Initialize ViGEm client and target using vigem-rust
    let client = Client::connect().expect("Failed to connect to ViGEmBus. Is it installed?");
    let x360 = client.new_x360_target().plugin().expect("Failed to plugin virtual controller");
    x360.wait_for_ready().expect("Failed to ready virtual controller");

    println!("Virtual Xbox Controller created successfully.");

    // 2. Setup UDP Socket to listen for incoming state packets
    let socket = UdpSocket::bind("0.0.0.0:9001").expect("Failed to bind UDP socket");
    println!("Listening for UDP packets on port 9001...");

    // We need to keep track of the Linux client's IP to send vibration data back
    let last_client_addr = Arc::new(Mutex::new(None::<SocketAddr>));
    let callback_addr = Arc::clone(&last_client_addr);
    let socket_clone = socket.try_clone().expect("Failed to clone UDP socket");

    // 3. Register Vibration (Rumble) Notification Receiver
    let notification_receiver = x360.register_notification().expect("Failed to register for notifications");
    
    // Spawn a separate thread to listen for rumble events from the game
    std::thread::spawn(move || {
        println!("Windows Rumble listener thread started successfully.");
        
        while let Ok(Ok(notification)) = notification_receiver.recv() {
            let l_motor = notification.large_motor;
            let s_motor = notification.small_motor;
            
            // Only output to console if there's actual vibration (to prevent log spamming)
            if l_motor > 0 || s_motor > 0 {
                println!("🎮 [VIBRATION RECEIVED] Large: {}, Small: {}", l_motor, s_motor);
            }

            // Lock and get the last known address of the Linux sender
            if let Some(addr) = *callback_addr.lock().unwrap() {
                // Send a simple 2-byte packet: [Large Motor, Small Motor]
                let rumble_packet = [l_motor, s_motor];
                let _ = socket_clone.send_to(&rumble_packet, addr);
            }
        }
    });

    let mut buf = [0u8; 12];
    let mut packet_count = 0u64;

    // 4. Main listening loop
    loop {
        match socket.recv_from(&mut buf) {
            Ok((size, src)) => {
                // Check if the received packet matches the expected size of ControllerState
                if size == std::mem::size_of::<ControllerState>() {
                    // Update the last known address so the vibration thread knows where to send
                    *last_client_addr.lock().unwrap() = Some(src);

                    // Unsafely cast the byte buffer into our struct
                    let state: ControllerState = unsafe { std::ptr::read_unaligned(buf.as_ptr() as *const _) };
                    
                    let mut report = X360Report::default();

                    // Pure Pass-through: Directly map received state to ViGEm report
                    report.thumb_lx = state.left_x;
                    report.thumb_ly = state.left_y;
                    report.thumb_rx = state.right_x;
                    report.thumb_ry = state.right_y;
                    report.left_trigger = state.left_trigger;
                    report.right_trigger = state.right_trigger;

                    // Map buttons from bitmask to vigem_rust's X360Button bitflags
                    if (state.buttons & BTN_UP) != 0 { report.buttons.insert(X360Button::DPAD_UP); }
                    if (state.buttons & BTN_DOWN) != 0 { report.buttons.insert(X360Button::DPAD_DOWN); }
                    if (state.buttons & BTN_LEFT) != 0 { report.buttons.insert(X360Button::DPAD_LEFT); }
                    if (state.buttons & BTN_RIGHT) != 0 { report.buttons.insert(X360Button::DPAD_RIGHT); }
                    if (state.buttons & BTN_START) != 0 { report.buttons.insert(X360Button::START); }
                    if (state.buttons & BTN_SELECT) != 0 { report.buttons.insert(X360Button::BACK); }
                    if (state.buttons & BTN_LS) != 0 { report.buttons.insert(X360Button::LEFT_THUMB); }
                    if (state.buttons & BTN_RS) != 0 { report.buttons.insert(X360Button::RIGHT_THUMB); }
                    if (state.buttons & BTN_LB) != 0 { report.buttons.insert(X360Button::LEFT_SHOULDER); }
                    if (state.buttons & BTN_RB) != 0 { report.buttons.insert(X360Button::RIGHT_SHOULDER); }
                    if (state.buttons & BTN_A) != 0 { report.buttons.insert(X360Button::A); }
                    if (state.buttons & BTN_B) != 0 { report.buttons.insert(X360Button::B); }
                    if (state.buttons & BTN_X) != 0 { report.buttons.insert(X360Button::X); }
                    if (state.buttons & BTN_Y) != 0 { report.buttons.insert(X360Button::Y); }
                    
                    // Send the updated state to the virtual controller
                    let _ = x360.update(&report);

                    // Debug logging
                    packet_count += 1;
                    if packet_count == 1 {
                        println!("First packet received from {}!", src);
                    }
                }
            }
            Err(e) => eprintln!("UDP Receive Error: {}", e),
        }
    }
}