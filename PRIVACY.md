# Data and Network Connections

Tez stores configurations and application state locally. Network activity follows the selected proxy configuration and the services configured in the application.

## Local Storage

The macOS application data directory is `~/Library/Application Support/app.tez.client/`.

| Content | Location |
| --- | --- |
| Application settings | `tez.yaml` |
| Core settings | `config.yaml` |
| Profile index and subscription metadata | `profiles.yaml` |
| Profile content and enhancements | `profiles/` |
| Application and sidecar logs | `logs/` |
| Service logs | `service-logs/` |
| Local backups | `tez-backup/` |

Native appearance and window preferences use the `app.tez.native` UserDefaults domain. The core service stores its runtime state under the Tez service directories.

Profiles can contain subscription URLs, proxy addresses, and credentials. Core logs can contain domains, IP addresses, and connection metadata. Export and backup operations include the files selected by that operation.

## Network Connections

| Action | Destination |
| --- | --- |
| Proxy traffic | The outbound routes in the active configuration |
| Subscription import and refresh | The subscription URL entered for the profile |
| Latency sampling | The configured test URL through the selected node |
| DNS resolution | The resolvers in the active DNS configuration |
| WebDAV backup | The configured WebDAV server |
| Release download | GitHub Releases |

Subscription refresh follows each profile's update settings. Latency sampling uses the selected test address and timeout. WebDAV transfers use the saved server address and credentials.

## Controls

Subscription settings control automatic updates and download routing. Settings expose DNS configuration, latency test parameters, and backup destinations. Activity provides connection and log inspection; log export writes the displayed records.

Project contact: [Tez Issues](https://github.com/Strugg1e/Tez/issues).
