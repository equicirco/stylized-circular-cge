module ScenarioExecution

using Dates
using Serialization
using SHA
using TOML

export checkpointed_grid, source_fingerprint, atomic_toml

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const RUN_DIR = joinpath(ROOT, "results", "run")

function atomic_write(writer, path)
    mkpath(dirname(path))
    temporary, io = mktemp(dirname(path))
    try
        writer(io)
        close(io)
        mv(temporary, path; force = true)
    catch
        isopen(io) && close(io)
        isfile(temporary) && rm(temporary)
        rethrow()
    end
    return path
end

atomic_toml(path, data) = atomic_write(io -> TOML.print(io, data), path)

function source_fingerprint(root = ROOT)
    files = [joinpath(root, "Project.toml"), joinpath(root, "Manifest.toml")]
    # Numerical checkpoints depend on model code, calibration data and the
    # locked environment. Editing downstream analytics must not force solves
    # to be repeated; experiment labels separately identify each grid design.
    for directory in ("src", "data")
        for (folder, _, names) in walkdir(joinpath(root, directory))
            append!(files, [joinpath(folder, name) for name in names
                if endswith(name, ".jl") || endswith(name, ".csv") || endswith(name, ".toml")])
        end
    end
    buffer = IOBuffer()
    for file in sort!(unique(files))
        isfile(file) || continue
        print(buffer, relpath(file, root), '\0')
        write(buffer, read(file))
        write(buffer, UInt8(0))
    end
    return bytes2hex(sha256(take!(buffer)))
end

"""
    checkpointed_grid(specs; executor, key, checkpoint_root, batch_size=64, kwargs...)

Run the existing model grid executor in batches, atomically save complete result
records, and resume saved batches only when source, dependencies, and case labels
match. Numerical non-convergence remains a normal result record. An exception
stops the run with completed batches preserved and an explicit failure status.
"""
function checkpointed_grid(specs; executor, key::AbstractString,
    checkpoint_root = get(ENV, "JCGE_CHECKPOINT_ROOT", joinpath(RUN_DIR, "checkpoints")),
    batch_size::Integer = parse(Int, get(ENV, "JCGE_CHECKPOINT_BATCH_SIZE", "64")),
    fingerprint::AbstractString = source_fingerprint(),
    kwargs...)
    batch_size > 0 || error("Checkpoint batch size must be positive")
    expected = get(ENV, "JCGE_RUN_FINGERPRINT", fingerprint)
    fingerprint == expected || error("Model or execution sources changed during this run")
    directory = joinpath(checkpoint_root, key)
    mkpath(directory)
    labels = [spec.label for spec in specs]
    length(unique(labels)) == length(labels) || error("Duplicate experiment labels for $(key)")
    solve_options = sort!([pair for pair in pairs(kwargs)
        if first(pair) ∉ (:execution, :workers, :worker_modules)]; by = pair -> string(first(pair)))
    configuration = Dict(
        "schema" => 1, "key" => String(key), "cases" => length(specs),
        "batch_size" => batch_size, "source_fingerprint" => String(fingerprint),
        "labels_sha256" => bytes2hex(sha256(join(labels, '\0'))),
        "solve_options" => [string(first(pair), "=", repr(last(pair))) for pair in solve_options],
    )
    manifest_path = joinpath(directory, "manifest.toml")
    if isfile(manifest_path)
        TOML.parsefile(manifest_path) == configuration ||
            error("Checkpoint configuration mismatch for $(key); archive it before a fresh run")
    else
        atomic_toml(manifest_path, configuration)
    end

    records = NamedTuple[]
    progress_path = joinpath(directory, "progress.toml")
    started = time()
    function progress(state; detail = "")
        atomic_toml(progress_path, Dict(
            "state" => state, "key" => String(key), "completed" => length(records),
            "total" => length(specs), "pid" => getpid(),
            "updated_at" => string(now(UTC)), "elapsed_seconds" => time() - started,
            "detail" => detail,
        ))
    end

    for (number, first_index) in enumerate(1:batch_size:length(specs))
        last_index = min(first_index + batch_size - 1, length(specs))
        path = joinpath(directory, "batch_$(lpad(number, 6, '0')).jls")
        expected_labels = labels[first_index:last_index]
        if isfile(path)
            saved = deserialize(path)
            saved.labels == expected_labels || error("Checkpoint labels mismatch in $(path)")
            saved.first_index == first_index && saved.last_index == last_index ||
                error("Checkpoint range mismatch in $(path)")
            saved.fingerprint == fingerprint || error("Checkpoint source mismatch in $(path)")
            length(saved.records) == length(expected_labels) || error("Incomplete checkpoint $(path)")
            [r.label for r in saved.records] == expected_labels ||
                error("Checkpoint result order mismatch in $(path)")
            append!(records, saved.records)
            progress("resuming")
            continue
        end

        progress("running"; detail = "batch $(number): cases $(first_index)-$(last_index)")
        println("[$(now(UTC))] $(key): $(length(records))/$(length(specs)) saved; starting batch $(number)")
        flush(stdout)
        heartbeat = Timer(30.0; interval = 30.0) do _
            println("[$(now(UTC))] $(key): batch $(number) running; $(length(records))/$(length(specs)) saved")
            flush(stdout)
        end
        try
            batch = executor(specs[first_index:last_index]; kwargs...)
            length(batch) == length(expected_labels) || error("Executor returned an incomplete batch")
            [r.label for r in batch] == expected_labels || error("Executor changed experiment order")
            atomic_write(path) do io
                serialize(io, (; first_index, last_index, labels = expected_labels,
                    fingerprint = String(fingerprint), records = NamedTuple[batch...]))
            end
            append!(records, batch)
            progress("running")
        catch err
            progress("failed"; detail = sprint(showerror, err))
            rethrow()
        finally
            close(heartbeat)
        end
    end
    progress("completed")
    println("[$(now(UTC))] $(key): $(length(records))/$(length(specs)) complete")
    flush(stdout)
    return records
end

end
