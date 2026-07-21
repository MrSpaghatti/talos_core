import mercury_core/llm_client
import std/json

let client = newLLMClient(
  baseUrl = "http://example.com",
  apiKey = "test-key",
  model = "test-model"
)
echo "LLMClient created successfully"
echo "Base URL: ", client.baseUrl
echo "Model: ", client.model
