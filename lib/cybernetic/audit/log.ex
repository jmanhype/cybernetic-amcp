defmodule Cybernetic.Audit.Log do
  @moduledoc """
  The audit log: an append-only, hash-chained record of what the
  system actually did (Phase 1, IP-27; design mechanism (b) — the
  roadmap narrowing of Issue #5).

  ## Shape

  One JSONL file per day under the configured directory
  (`config :cybernetic, :audit_log_dir`), named
  `audit-YYYY-MM-DD.jsonl`. Each line is one entry:

      %{
        "seq" => global sequence number,
        "ts" => ISO8601 timestamp,
        "type" => event type (e.g. "algedonic_signal"),
        "payload" => event payload (JSON-safe map),
        "prev_hash" => hash of the previous entry,
        "hash" => sha256(prev_hash <> canonical(entry))
      }

  The final entry of each completed day is a `daily_anchor` whose
  payload carries the Merkle root of that day's entry hashes — the
  one element imported from Issue #5's full spec. Named non-goals
  (deferred, addable without redesign): an external timestamp
  authority, a verification API, per-entry Merkle proofs, and
  continuous (<100 ms) tamper detection.

  ## Independence

  This process sits outside the VSM supervision subtree: it is a
  root child of `Cybernetic.Application`, so no VSM system
  supervises, restarts, or configures it. Writers call
  `record/2`; readers query through `entries_between/2` or verify
  the files directly from disk (`verify_file/1`, `verify_dir/1`,
  `mix cyb.audit_verify`) without the running system's cooperation.

  What the chain proves: modification, deletion, or reordering of
  recorded entries is detectable. What it does not prove: that
  everything was recorded (omission is invisible to any chain), or
  that a payload was true when written.

  `record/2` is a cast and never blocks or crashes the writer: if
  the log is not running (e.g. minimal test mode), recording is a
  no-op. Recording seams therefore stay safe in every environment.
  """

  use GenServer
  require Logger

  @genesis_hash "GENESIS"
  @anchor_type "daily_anchor"

  # ========== CLIENT API ==========

  @doc """
  Child specification (root child of `Cybernetic.Application`).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Starts the audit log.

  Options:
    * `:dir` - directory holding the JSONL files (default: the
      `:audit_log_dir` application config, itself defaulting to
      `"priv/audit"`)
    * `:name` - registration name (default: `Cybernetic.Audit.Log`)
    * `:clock` - zero-arity function returning the current
      `DateTime` (default: `DateTime.utc_now/0`); tests inject a
      controllable clock to exercise day rotation
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records an event. Fire-and-forget: returns `:ok` immediately and
  is a no-op when the log process is not running, so writers at the
  seam never crash on the audit path.

  The log assigns the sequence number, timestamp, and chain hashes;
  the payload is sanitized to JSON-safe data before hashing, so
  atoms become strings and tuples become lists.
  """
  @spec record(atom() | String.t(), map()) :: :ok
  def record(type, payload) when is_map(payload) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, type, payload})
    end

    :ok
  end

  @doc """
  Returns decoded entries whose timestamps fall in `[from, to]`
  (either bound may be `nil` for unbounded), in sequence order.
  Returns `[]` when the log is not running.
  """
  @spec entries_between(DateTime.t() | nil, DateTime.t() | nil) :: [map()]
  def entries_between(from \\ nil, to \\ nil) do
    GenServer.call(__MODULE__, {:entries_between, from, to})
  catch
    :exit, {:noproc, _} -> []
  end

  @doc """
  Returns `{seq, hash}` of the most recent entry, or `nil` when the
  log is empty or not running.
  """
  @spec head() :: {non_neg_integer(), String.t()} | nil
  def head do
    GenServer.call(__MODULE__, :head)
  catch
    :exit, {:noproc, _} -> nil
  end

  @doc """
  Verifies the whole chain in this log's directory (see
  `verify_dir/1`). Returns `{:error, :not_running}` when the log is
  not running.
  """
  @spec verify_chain() :: {:ok, map()} | {:error, map() | :not_running}
  def verify_chain do
    GenServer.call(__MODULE__, :verify_chain)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  # ========== VERIFICATION (pure; reads files directly) ==========

  @doc """
  Computes an entry's chain hash:
  `sha256(prev_hash <> term_to_binary({seq, ts, type, payload}))`,
  hex-encoded. `payload` must already be JSON-safe (see
  `record/2`); verification recomputes from the decoded payload,
  which round-trips exactly.
  """
  @spec entry_hash(non_neg_integer(), String.t(), String.t(), map(), String.t()) ::
          String.t()
  def entry_hash(seq, ts, type, payload, prev_hash) do
    canonical = :erlang.term_to_binary({seq, ts, type, payload})
    :crypto.hash(:sha256, prev_hash <> canonical) |> Base.encode16(case: :lower)
  end

  @doc """
  Merkle root of a list of entry hashes (hex strings). Pairs are
  hashed as `sha256(left <> right)`; an odd trailing hash is
  duplicated (Bitcoin-style). The root of a single hash is the hash
  itself; the root of no hashes is the sha256 of the empty string.
  """
  @spec merkle_root([String.t()]) :: String.t()
  def merkle_root([]), do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
  def merkle_root([single]), do: single

  def merkle_root(hashes) do
    hashes
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [left, right] -> :crypto.hash(:sha256, left <> right) |> Base.encode16(case: :lower)
      [left] -> :crypto.hash(:sha256, left <> left) |> Base.encode16(case: :lower)
    end)
    |> merkle_root()
  end

  @doc """
  Verifies one JSONL audit file: every line parses, sequence
  numbers are consecutive within the file, each `prev_hash` matches
  the previous entry's hash, each `hash` recomputes, and any
  `daily_anchor` entry's Merkle root and entry count match the
  entries preceding it in the file.

  Returns `{:ok, info}` or `{:error, detail}` where detail names
  the first bad entry's `seq` and the `reason`.
  """
  @spec verify_file(Path.t()) :: {:ok, map()} | {:error, map()}
  def verify_file(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: true)

        case verify_lines(lines) do
          {:ok, acc} ->
            {:ok,
             %{
               file: path,
               entries: acc.count,
               anchors: acc.anchors,
               first_seq: acc.first_seq,
               last_seq: acc.last_seq,
               last_hash: acc.last_hash
             }}

          {:error, detail} ->
            {:error, Map.put(detail, :file, path)}
        end

      {:error, reason} ->
        {:error, %{file: path, seq: nil, reason: :unreadable, detail: reason}}
    end
  end

  @doc """
  Verifies every audit file in `dir`: each file verifies (see
  `verify_file/1`), the chain is continuous across files (sequence
  and `prev_hash` link file boundaries), and every file for a past
  day ends with its `daily_anchor` entry (today's file is exempt —
  its anchor is written when the day closes).
  """
  @spec verify_dir(Path.t()) :: {:ok, map()} | {:error, map()}
  def verify_dir(dir) do
    files =
      dir
      |> audit_files()
      |> Enum.map(&Path.join(dir, &1))

    with {:ok, infos} <- verify_all_files(files),
         :ok <- check_cross_file_chain(dir, infos),
         :ok <- check_past_days_anchored(dir) do
      {:ok,
       %{
         files: length(infos),
         entries: infos |> Enum.map(& &1.entries) |> Enum.sum(),
         anchors: infos |> Enum.map(& &1.anchors) |> Enum.sum()
       }}
    end
  end

  @doc """
  The file name for a day's audit file.
  """
  @spec file_name(Date.t()) :: String.t()
  def file_name(date), do: "audit-#{Date.to_string(date)}.jsonl"

  # ========== GENSERVER CALLBACKS ==========

  @impl true
  def init(opts) do
    dir =
      Keyword.get(opts, :dir) ||
        Application.get_env(:cybernetic, :audit_log_dir, "priv/audit")

    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    File.mkdir_p!(dir)

    state = %{
      dir: dir,
      clock: clock,
      # Date of the day currently being appended to (nil until the
      # first entry or a recovered file establishes it)
      date: nil,
      seq: 0,
      prev_hash: @genesis_hash,
      # Hashes of the current day's non-anchor entries, for the
      # anchor's Merkle root
      day_hashes: []
    }

    {:ok, recover_state(state)}
  end

  @impl true
  def handle_cast({:record, type, payload}, state) do
    {:noreply, append_entry(state, type, payload)}
  end

  @impl true
  def handle_call({:entries_between, from, to}, _from, state) do
    entries =
      state.dir
      |> audit_files()
      |> Enum.flat_map(fn name -> read_entries(Path.join(state.dir, name)) end)
      |> Enum.filter(&entry_in_range?(&1, from, to))
      |> Enum.sort_by(& &1["seq"])

    {:reply, entries, state}
  end

  def handle_call(:head, _from, state) do
    reply = if state.seq == 0, do: nil, else: {state.seq, state.prev_hash}
    {:reply, reply, state}
  end

  def handle_call(:verify_chain, _from, state) do
    {:reply, verify_dir(state.dir), state}
  end

  # ========== APPEND / ROTATION ==========

  defp append_entry(state, type, payload) do
    now = state.clock.()
    today = DateTime.to_date(now)

    state = maybe_rotate(state, today)

    entry = build_entry(state, now, to_string(type), json_safe(payload))
    write_line(state.dir, file_name(state.date), entry)

    %{
      state
      | seq: entry["seq"],
        prev_hash: entry["hash"],
        day_hashes: state.day_hashes ++ [entry["hash"]]
    }
  end

  # On the first append, adopt today. When the day has advanced,
  # close the previous day with its anchor before opening the new
  # day. A clock moving backwards keeps appending to the open day.
  defp maybe_rotate(%{date: nil} = state, today), do: %{state | date: today}

  defp maybe_rotate(state, today) do
    if Date.compare(today, state.date) == :gt do
      state = close_day(state)
      %{state | date: today, day_hashes: []}
    else
      state
    end
  end

  # Appends the daily anchor for the state's current day and returns
  # state advanced past it. The anchor chains like any entry but is
  # not part of its own Merkle root.
  defp close_day(state) do
    if state.day_hashes == [] do
      state
    else
      now = state.clock.()

      payload = %{
        "date" => Date.to_string(state.date),
        "entries" => length(state.day_hashes),
        "merkle_root" => merkle_root(state.day_hashes)
      }

      entry = build_entry(state, now, @anchor_type, payload)
      write_line(state.dir, file_name(state.date), entry)

      %{state | seq: entry["seq"], prev_hash: entry["hash"]}
    end
  end

  defp build_entry(state, now, type, payload) do
    seq = state.seq + 1
    ts = DateTime.to_iso8601(now)
    hash = entry_hash(seq, ts, type, payload, state.prev_hash)

    %{
      "seq" => seq,
      "ts" => ts,
      "type" => type,
      "payload" => payload,
      "prev_hash" => state.prev_hash,
      "hash" => hash
    }
  end

  defp write_line(dir, name, entry) do
    line = Jason.encode!(entry) <> "\n"
    File.write!(Path.join(dir, name), line, [:append])
  end

  # ========== RECOVERY ==========

  # Rebuilds chain state from the newest file on disk. If the newest
  # file belongs to a past day and has no anchor yet (the process
  # was down across midnight), the day is closed first, so the
  # invariant "past days end with an anchor" holds from boot.
  defp recover_state(state) do
    today = DateTime.to_date(state.clock.())

    case audit_files(state.dir) do
      [] ->
        state

      names ->
        newest = List.last(names)
        entries = read_entries(Path.join(state.dir, newest))

        case List.last(entries) do
          nil ->
            state

          last ->
            file_date = file_date(newest)

            recovered = %{
              state
              | date: file_date,
                seq: last["seq"],
                prev_hash: last["hash"],
                day_hashes:
                  entries
                  |> Enum.reject(&(&1["type"] == @anchor_type))
                  |> Enum.map(& &1["hash"])
            }

            cond do
              file_date == today ->
                recovered

              Date.compare(file_date, today) == :lt and last["type"] != @anchor_type ->
                recovered = close_day(recovered)
                %{recovered | date: today, day_hashes: []}

              true ->
                recovered
            end
        end
    end
  end

  # ========== FILE READING / VERIFICATION HELPERS ==========

  defp audit_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/\Aaudit-\d{4}-\d{2}-\d{2}\.jsonl\z/, &1))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp file_date("audit-" <> rest) do
    rest |> String.trim_trailing(".jsonl") |> Date.from_iso8601!()
  end

  defp read_entries(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, entry} -> entry
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp entry_in_range?(entry, from, to) do
    case DateTime.from_iso8601(entry["ts"]) do
      {:ok, ts, _offset} ->
        (is_nil(from) or DateTime.compare(ts, from) != :lt) and
          (is_nil(to) or DateTime.compare(ts, to) != :gt)

      {:error, _} ->
        false
    end
  end

  defp verify_all_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn path, {:ok, infos} ->
      case verify_file(path) do
        {:ok, info} -> {:cont, {:ok, infos ++ [info]}}
        {:error, detail} -> {:halt, {:error, detail}}
      end
    end)
  end

  defp check_cross_file_chain(_dir, infos) do
    infos
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn [prev, next], :ok ->
      cond do
        not is_nil(next.first_seq) and not is_nil(prev.last_seq) and
            next.first_seq != prev.last_seq + 1 ->
          {:halt,
           {:error,
            %{
              file: next.file,
              seq: next.first_seq,
              reason: :seq_gap_across_files,
              detail: %{expected_seq: prev.last_seq + 1}
            }}}

        true ->
          # prev_hash linkage across the boundary is checked from
          # the raw first entry of the next file.
          case first_entry_prev_hash(next.file) do
            {:ok, prev_hash} when prev_hash == prev.last_hash or is_nil(prev.last_hash) ->
              {:cont, :ok}

            {:ok, _other} ->
              {:halt,
               {:error,
                %{
                  file: next.file,
                  seq: next.first_seq,
                  reason: :prev_hash_mismatch_across_files,
                  detail: %{expected_prev_hash: prev.last_hash}
                }}}

            :empty ->
              {:cont, :ok}
          end
      end
    end)
  end

  defp first_entry_prev_hash(path) do
    case read_entries(path) do
      [first | _] -> {:ok, first["prev_hash"]}
      [] -> :empty
    end
  end

  defp check_past_days_anchored(dir) do
    today = Date.utc_today()

    dir
    |> audit_files()
    |> Enum.filter(fn name -> Date.compare(file_date(name), today) == :lt end)
    |> Enum.reduce_while(:ok, fn name, :ok ->
      entries = read_entries(Path.join(dir, name))

      case List.last(entries) do
        %{"type" => @anchor_type} ->
          {:cont, :ok}

        _other ->
          {:halt,
           {:error,
            %{
              file: Path.join(dir, name),
              seq: nil,
              reason: :missing_daily_anchor,
              detail: %{date: file_date(name)}
            }}}
      end
    end)
  end

  defp verify_lines(lines) do
    initial = %{
      count: 0,
      anchors: 0,
      first_seq: nil,
      last_seq: nil,
      last_hash: nil,
      # Hashes since the last anchor (the anchor's root covers the
      # whole file in practice: one anchor, at the end)
      root_hashes: []
    }

    Enum.reduce_while(lines, {:ok, initial}, fn line, {:ok, acc} ->
      case verify_line(line, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, detail} -> {:halt, {:error, detail}}
      end
    end)
  end

  defp verify_line(line, acc) do
    case Jason.decode(line) do
      {:error, _} ->
        {:error, %{seq: nil, reason: :invalid_json, detail: %{line: line}}}

      {:ok, entry} ->
        seq = entry["seq"]

        cond do
          not is_nil(acc.last_seq) and seq != acc.last_seq + 1 ->
            {:error, %{seq: seq, reason: :seq_gap, detail: %{expected_seq: acc.last_seq + 1}}}

          not is_nil(acc.last_hash) and entry["prev_hash"] != acc.last_hash ->
            {:error,
             %{
               seq: seq,
               reason: :prev_hash_mismatch,
               detail: %{expected_prev_hash: acc.last_hash}
             }}

          entry["hash"] !=
              entry_hash(seq, entry["ts"], entry["type"], entry["payload"], entry["prev_hash"]) ->
            {:error, %{seq: seq, reason: :hash_mismatch, detail: %{}}}

          entry["type"] == @anchor_type ->
            verify_anchor(entry, acc)

          true ->
            {:ok,
             %{
               acc
               | count: acc.count + 1,
                 first_seq: acc.first_seq || seq,
                 last_seq: seq,
                 last_hash: entry["hash"],
                 root_hashes: acc.root_hashes ++ [entry["hash"]]
             }}
        end
    end
  end

  defp verify_anchor(entry, acc) do
    payload = entry["payload"]
    expected_root = merkle_root(acc.root_hashes)

    cond do
      payload["merkle_root"] != expected_root ->
        {:error,
         %{
           seq: entry["seq"],
           reason: :anchor_root_mismatch,
           detail: %{expected_root: expected_root}
         }}

      payload["entries"] != length(acc.root_hashes) ->
        {:error,
         %{
           seq: entry["seq"],
           reason: :anchor_count_mismatch,
           detail: %{expected_entries: length(acc.root_hashes)}
         }}

      true ->
        {:ok,
         %{
           acc
           | count: acc.count + 1,
             anchors: acc.anchors + 1,
             first_seq: acc.first_seq || entry["seq"],
             last_seq: entry["seq"],
             last_hash: entry["hash"],
             root_hashes: []
         }}
    end
  end

  # ========== PAYLOAD SANITIZATION ==========

  # Converts a writer's payload to JSON-safe data deterministically:
  # map keys become strings, atoms become strings (nil/booleans are
  # preserved), tuples become lists, and opaque terms (pids, refs)
  # become their inspect strings. The hash is computed over this
  # form, and JSON decoding a stored line reproduces it exactly.
  defp json_safe(term) when is_map(term) do
    Map.new(term, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(term) when is_list(term), do: Enum.map(term, &json_safe/1)
  defp json_safe(term) when is_tuple(term), do: term |> Tuple.to_list() |> json_safe()

  defp json_safe(term) when is_atom(term) and term not in [nil, true, false],
    do: Atom.to_string(term)

  defp json_safe(term)
       when is_pid(term) or is_reference(term) or is_function(term) or is_port(term),
       do: inspect(term)

  defp json_safe(term), do: term
end
