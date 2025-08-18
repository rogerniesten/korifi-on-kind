# Inside .env
ENV_PATH="$(realpath "${BASH_SOURCE[0]}")"
ENV_DIR="$(dirname "$ENV_PATH")"

echo "This .env file lives at: $ENV_PATH"
echo "Directory: $ENV_DIR"

