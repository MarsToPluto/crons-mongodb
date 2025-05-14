# Start from the official MongoDB image you are already using
FROM mongo:latest

# Install the zip utility
# The mongo:latest image is Debian-based
RUN apt-get update && apt-get install -y zip && rm -rf /var/lib/apt/lists/*