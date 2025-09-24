# Use the official ROS Jazzy base image from Docker Hub
FROM ros:jazzy

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Update package list and install ros-jazzy-desktop-full
# The base ROS image should already have the ROS repositories configured
RUN apt-get update && \
    apt-get install -y \
        ros-jazzy-desktop-full && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the default command
CMD ["bash"]
