defmodule Cybernetic.Transport.Message do
  @moduledoc """
  Message normalization utilities for consistent message handling across transports.
  Ensures all messages have a canonical shape for security validation and processing.
  """

  @doc """
  Normalize a message to canonical shape expected by NonceBloom and other components.
  
  Flattens security headers from nested structures to top-level for NonceBloom validation.
  
  Expected canonical shape:
  %{
    "headers" => %{...},
    "payload" => %{...},
    "_nonce" => "...",
    "_timestamp" => 123456789,
    "_site" => "node@host", 
    "_signature" => "..."
  }
  """
  def normalize(message) when is_map(message) do
    message
    |> flatten_security_headers()
  end
  
  def normalize(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"payload" => binary}
    end
  end
  
  def normalize(other) do
    %{"payload" => other}
  end
  
  @doc """
  Extract payload from normalized message, stripping transport metadata.
  """
  def extract_payload(%{"payload" => payload}), do: payload
  def extract_payload(message), do: message
  
  @doc """
  Check if message has security envelope (NonceBloom headers).
  """
  def has_security_envelope?(message) do
    Map.has_key?(message, "_nonce") and 
    Map.has_key?(message, "_timestamp") and
    Map.has_key?(message, "_signature")
  end
  
  @doc """
  Get message type from various possible locations.
  """
  def get_type(%{"type" => type}), do: type
  def get_type(%{"payload" => %{"type" => type}}), do: type
  def get_type(%{"headers" => %{"type" => type}}), do: type
  def get_type(_), do: nil
end