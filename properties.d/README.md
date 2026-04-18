# Bedrock Property Profiles

Each server can have an optional partial `server.properties` profile in this directory.

File naming convention:
- `<server-name>.server.properties`

Example:
```ini
server-name=My Bedrock Server
gamemode=survival
difficulty=normal
allow-cheats=false
max-players=10
level-name=MyWorld
level-seed=
```

Only keys present in the profile are applied. Missing keys are left unchanged in the target server properties file.
