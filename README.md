# jazzy-desktop-full

This repository contains a Docker image based on the official ROS Jazzy image with the `ros-jazzy-desktop-full` meta package installed. The image is automatically built and published nightly to GitHub Container Registry.

## Features

- Based on official ROS Jazzy Docker image
- Includes ROS Jazzy Desktop-Full meta package
- Multi-architecture support (amd64, arm64)
- Automated nightly builds via GitHub Actions

## Usage

### Pull the latest image

```bash
docker pull ghcr.io/mbloechli/jazzy-desktop-full:latest
```

### Run the container

```bash
# Basic usage
docker run -it ghcr.io/mbloechli/jazzy-desktop-full:latest

# Run with GUI support (X11 forwarding on Linux)
docker run -it --rm \
  --env="DISPLAY" \
  --volume="/tmp/.X11-unix:/tmp/.X11-unix:rw" \
  ghcr.io/mbloechli/jazzy-desktop-full:latest

# Run with network host mode for ROS communication
docker run -it --rm --network host \
  ghcr.io/mbloechli/jazzy-desktop-full:latest
```

### Available tags

- `latest` - Latest build from main branch
- `nightly` - Nightly automated builds
- `main` - Latest build from main branch

## Building locally

```bash
git clone https://github.com/mbloechli/jazzy-desktop-full.git
cd jazzy-desktop-full
docker build -t jazzy-desktop-full .
```

## Automated builds

The Docker image is automatically built and published:
- Every night at 2 AM UTC
- On every push to the main branch
- Can be manually triggered via GitHub Actions

The image is published to GitHub Container Registry at `ghcr.io/mbloechli/jazzy-desktop-full`.
