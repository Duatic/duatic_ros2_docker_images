# jazzy-desktop-full

This repository contains a Docker image based on the official ROS Jazzy image with the `ros-jazzy-desktop-full` meta package installed.

## Features

- Based on official ROS Jazzy Docker image
- Includes ROS Jazzy Desktop-Full meta package
- Multi-architecture support (amd64, arm64)

## Usage

### Pull the latest image

```bash
docker pull ghcr.io/duatic/duatic_ros2_docker_images:latest
```

### Run the container

```bash
# Basic usage
docker run -it ghcr.io/duatic/duatic_ros2_docker_images:latest

# Run with GUI support (X11 forwarding on Linux)
docker run -it --rm \
  --env="DISPLAY" \
  --volume="/tmp/.X11-unix:/tmp/.X11-unix:rw" \
  ghcr.io/duatic/duatic_ros2_docker_images:latest

# Run with network host mode for ROS communication
docker run -it --rm --network host \
  ghcr.io/duatic/duatic_ros2_docker_images:latest
```

### Available tags

- `latest` - Latest build from main branch
- `main` - Latest build from main branch

## Building locally

```bash
git clone ghcr.io/duatic/duatic_ros2_docker_images:latest
cd jazzy-desktop-full
docker build -t jazzy-desktop-full .
```

## Automated builds

The Docker image build and publish can be manually triggered via GitHub Actions.

The image is published to GitHub Container Registry at `ghcr.io/duatic/duatic_ros2_docker_images:latest`.
