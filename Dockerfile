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

# Set up the ROS environment
RUN echo "source /opt/ros/jazzy/setup.bash" >> ~/.bashrc

# Create a non-root user for better security practices
RUN useradd -ms /bin/bash ros && \
    echo "source /opt/ros/jazzy/setup.bash" >> /home/ros/.bashrc

# Switch to the ros user
USER ros
WORKDIR /home/ros

# Set the default command
CMD ["bash"]