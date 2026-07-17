# Privacy

SteamPack processes power, battery, and thermal state locally on the Mac.

It does not collect telemetry or analytics, create an account, contact a network service, store an administrator password, or transmit user data. Local state files contain requested and applied Boolean control state; the request source; a rollback snapshot and expiry deadline for an in-flight Control Center action; its applied acknowledgement source and result; a monotonic revision watermark and timestamps; and crash-recovery ownership metadata: a random lease token, owner process ID, lease creation time, and owner process start time.
