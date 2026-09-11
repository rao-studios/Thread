# Build stage
FROM swift:6.0.0-jammy AS builder

WORKDIR /build

# Copy package files first for better layer caching
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Copy source code
COPY . .

# Build release binary
RUN swift build -c release

# Runtime stage
FROM swift:6.0.0-jammy-slim

WORKDIR /app

# Copy the actual binary
COPY --from=builder /build/.build/release/thread /app/

# Expose port
EXPOSE 8080

# Run with the correct flags
CMD ["/app/thread", "--host", "0.0.0.0", "--port", "8080", "--mothership-host", "10.0.0.132"]
