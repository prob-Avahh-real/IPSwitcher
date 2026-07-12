# IP Switcher

A VPN-based IP switching tool for iOS that routes traffic through proxy nodes across different regions.

## Features
- Shadowsocks proxy protocol support
- Subscription import (JSON, Base64, SIP008, Surge format)
- Node management with region detection
- VPN tunnel via NEPacketTunnelProvider
- Keychain-secured credential storage
- Traffic statistics monitoring
- DNS leak protection and kill switch
- Quick connect with lowest-latency selection

## Architecture
- MVVM pattern with ObservableObject
- Core/ layer with Configuration, Network, Persistence, Utilities
- NEPacketTunnelProvider extension for VPN tunnel
- KeychainManager for secure password storage
- ConfigService with multi-format subscription parsing

## Requirements
- iOS 16.0+
- Xcode 15.0+
- VPN entitlement

## Security
- Passwords stored in Keychain with `AfterFirstUnlockThisDeviceOnly` protection
- Password references (persistent ref) passed to NEVPNProtocol
- ATS disabled (NSAllowsArbitraryLoads) required for VPN functionality
