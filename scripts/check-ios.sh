#!/bin/bash

# Exit on error
set -e

echo "Checking iOS code..."

# Install SwiftLint if not installed
if ! command -v swiftlint &> /dev/null; then
    echo "SwiftLint not found. Installing..."
    brew install swiftlint
fi

# Run SwiftLint
cd ios
echo "Running SwiftLint..."
swiftlint lint --quiet

echo "iOS checks completed successfully!" 