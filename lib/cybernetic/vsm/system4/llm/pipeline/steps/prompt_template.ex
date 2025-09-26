defmodule Cybernetic.VSM.System4.LLM.Pipeline.Steps.PromptTemplate do
  @moduledoc """
  Normalize messages and apply templating if needed.
  
  Converts Episode structs and other formats to normalized message format.
  """

  require Logger

  @doc """
  Normalize messages for LLM consumption.
  """
  def run(%{episode: episode} = ctx) when not is_nil(episode) do
    # Convert Episode to messages format
    messages = episode_to_messages(episode)
    {:ok, Map.put(ctx, :messages, messages)}
  end

  def run(%{messages: messages} = ctx) when is_list(messages) do
    # Normalize existing messages
    normalized = normalize_messages(messages)
    {:ok, Map.put(ctx, :messages, normalized)}
  end

  def run(%{prompt: prompt} = ctx) when is_binary(prompt) do
    # Simple prompt to messages
    messages = [%{role: "user", content: prompt}]
    {:ok, Map.put(ctx, :messages, messages)}
  end

  def run(ctx) do
    # No messages to process
    Logger.warning("PromptTemplate: No messages to process")
    {:ok, ctx}
  end

  defp episode_to_messages(episode) do
    # Convert Episode struct to message format
    system_prompt = build_system_prompt(episode)
    user_content = build_user_content(episode)
    
    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_content}
    ]
    
    # Add context messages if present
    case episode[:context] do
      messages when is_list(messages) ->
        system_message = List.first(messages)
        rest = messages ++ [%{role: "user", content: user_content}]
        [system_message | rest]
      
      _ ->
        messages
    end
  end

  defp build_system_prompt(episode) do
    """
    You are analyzing an episode from the VSM System 4 Intelligence layer.
    Episode Kind: #{episode.kind}
    Priority: #{episode.priority}
    
    Provide intelligent analysis and recommendations based on the data provided.
    """
  end

  defp build_user_content(episode) do
    data_str = case episode.data do
      data when is_binary(data) -> data
      data -> inspect(data)
    end
    
    """
    Analyze the following data:
    
    #{data_str}
    
    Context:
    - Source: #{episode.source}
    - Timestamp: #{episode.timestamp}
    #{if episode[:metadata], do: "- Metadata: #{inspect(episode.metadata)}"}
    """
  end

  defp normalize_messages(messages) do
    Enum.map(messages, &normalize_message/1)
  end

  defp normalize_message(%{role: role, content: content} = msg) do
    %{
      role: to_string(role),
      content: to_string(content)
    }
    |> maybe_add_name(msg)
  end

  defp normalize_message(%{"role" => role, "content" => content} = msg) do
    %{
      role: to_string(role),
      content: to_string(content)
    }
    |> maybe_add_name(msg)
  end

  defp normalize_message(msg) when is_map(msg) do
    %{
      role: to_string(msg[:role] || msg["role"] || "user"),
      content: to_string(msg[:content] || msg["content"] || "")
    }
  end

  defp maybe_add_name(normalized, original) do
    case original[:name] || original["name"] do
      nil -> normalized
      name -> Map.put(normalized, :name, to_string(name))
    end
  end
end