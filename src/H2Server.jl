module H2Server

using Sockets
using ..H2Types: ConnectionRole, SERVER, HTTP2Connection, HTTP2Stream, HTTP2Request, is_server, is_client
using ..H2Types
using ..Exc, ..Connection, ..Streams, ..H2Settings, ..H2TLSIntegration 
using HPACK
using H2Frames
export HTTP2Server, serve, push_promise!

mutable struct HTTP2Server
    socket::Sockets.TCPServer
    handler::Any 
    settings::HTTP2Settings
end

"""
    serve(handler, host, port; ...)

Start a robust HTTP/2 server.
Accepts a native H2 handler of the form: `f(conn::HTTP2Connection, stream::HTTP2Stream)`.
These changes allow easy TLS customization.
"""
function serve(handler, host::AbstractString="0.0.0.0", port::Integer=8080; 
             is_tls=true, cert_file::String, key_file::String, ready_channel=nothing, settings::Union{HTTP2Settings, Nothing}=nothing, kwargs...)

    server_socket = listen(Sockets.getaddrinfo(host), port)
    
    if ready_channel !== nothing
        put!(ready_channel, true)
    end

    server_settings = (settings === nothing) ? create_server_settings() : settings 

    @info "H2 Server listening on $host:$port (TLS: $is_tls)..."
    
    try
        while isopen(server_socket)
            sock = Sockets.accept(server_socket)
            
            @async handle_new_connection(sock, server_settings, handler, host, port; 
                                        is_tls=is_tls, cert_file=cert_file, key_file=key_file, kwargs...)
        end
    catch e
        if !(e isa InterruptException || e isa Base.IOError)
            @error "Server accept loop error" exception=(e, catch_backtrace())
        end
    finally
        close(server_socket)
        @info "Server shut down."
    end
end

"""
    handle_new_connection(sock, settings, handler, ...; kwargs...)

Handles a new incoming connection, performs the TLS handshake,
and starts the HTTP/2 connection preface.
"""
function handle_new_connection(sock::IO, settings::HTTP2Settings, handler, host::String, port::Int64;
                             is_tls=true, cert_file::String, key_file::String, kwargs...)
    conn = nothing
    try
        io = is_tls ?
            H2TLSIntegration.tls_accept(sock; cert_file=cert_file, key_file=key_file, kwargs...) : sock
        
        conn = HTTP2Connection(io, SERVER, settings, host, port; request_handler=handler)
        
        Connection.start_connection_loops!(conn)

        Connection.receive_preface!(conn)
        
        Connection.send_preface!(conn)
        
        while isopen(conn.socket)
            yield()
            sleep(0.01) 
        end

    catch e
        if !(e isa EOFError || (e isa Base.IOError && e.code in (-54, -104))) 
            @error "Connection setup failed" exception=(e, catch_backtrace())
        end
    finally
        if conn !== nothing && !is_closed(conn)
            close_connection!(conn, :PROTOCOL_ERROR, "Connection teardown")
        elseif isopen(sock)
            close(sock)
        end
    end
end

"""
    push_promise!(conn::HTTP2Connection, original_stream::HTTP2Stream, method::String, path::String, headers::Vector{<:Pair}=Pair{String, String}[])

A higher-level helper for server push. Automatically creates the required pseudo-headers
and sends a PUSH_PROMISE frame. Returns the promised stream.
"""
function push_promise!(conn::HTTP2Connection, original_stream::HTTP2Stream, method::String, path::String, headers::Vector{<:Pair}=Pair{String, String}[])
    # Automatically determine scheme and authority from the connection
    scheme = isa(conn.socket, MbedTLS.SSLContext) ? "https" : "http"
    authority = conn.host # Assuming conn.host stores the authority (e.g., "localhost:8080")

    # Construct the full set of request headers for the promised resource
    request_headers = [
        ":method" => method,
        ":scheme" => scheme,
        ":authority" => authority,
        ":path" => path
    ]
    append!(request_headers, headers)

    # Call the existing, lower-level push_promise! function
    return push_promise!(conn, original_stream, request_headers)
end

"""
    push_promise!(conn::HTTP2Connection, original_stream::HTTP2Stream, request_headers::Vector{<:Pair})

Send a HTTP/2 PUSH_PROMISE frame for server push.
Returns the promised stream if successful, otherwise nothing.
"""
function push_promise!(conn::HTTP2Connection, original_stream::HTTP2Stream, request_headers::Vector{<:Pair})
    if !is_open(conn) || !conn.remote_settings.enable_push
        @warn "Cannot send PUSH_PROMISE: Push disabled by client or connection not open."
        return nothing
    end

    local promised_stream
    local push_promise_frame

    # Step 1: Lock *only* to modify the shared stream state
    @lock conn.streams_lock begin
        if length(conn.streams) >= conn.remote_settings.max_concurrent_streams
            @warn "Cannot send PUSH_PROMISE: Max concurrent streams reached."
            return nothing
        end

        promised_stream_id = conn.last_stream_id
        conn.last_stream_id += 2
        
        promised_stream = HTTP2Stream(promised_stream_id, conn)
        add_stream(conn, promised_stream)
        register_stream!(conn.multiplexer, promised_stream)
        transition_stream_state!(promised_stream, :send_push_promise)

        header_block = HPACK.encode_headers(conn.hpack_encoder, request_headers)
        
        push_promise_frame = H2Frames.PushPromiseFrame(
            original_stream.id,
            promised_stream.id,
            header_block
        )
    end # End of lock

    # Step 2: Perform the network I/O *outside* the state lock
    @info "[PushPromise] Sending PUSH_PROMISE frame for stream $(promised_stream.id)."
    Connection.send_frame(conn, serialize_frame(push_promise_frame))
    @info "[PushPromise] Successfully sent PUSH_PROMISE for stream $(promised_stream.id)."
    
    return promised_stream
end

"""
    HTTP2Handler

Abstract type for HTTP/2 request handlers.
"""
abstract type HTTP2Handler end

"""
    handle_request(handler::HTTP2Handler, req::HTTP2Request) -> HTTP2Response

Handle an HTTP/2 request and return an HTTP/2 response.
Override this method for custom handlers.
"""
function handle_request(handler::HTTP2Handler, req::HTTP2Request)
    throw(MethodError(handle_request, (handler, req)))
end

"""
    DefaultHandler <: HTTP2Handler

A simple handler that always returns 404 Not Found.
"""
struct DefaultHandler <: HTTP2Handler end

function handle_request(::DefaultHandler, req::HTTP2Request)
    return HTTP2Response(
        404,
        [ "content-type" => "text/plain" ],
        Vector{UInt8}("Not Found"),
        req.stream_id
    )
end

"""
    route(handler_map::Dict{String,HTTP2Handler}, req::HTTP2Request) -> HTTP2Response

Route the request to the appropriate handler based on the path.
"""
function route(handler_map::Dict{String,HTTP2Handler}, req::HTTP2Request)
    h = get(handler_map, req.path, DefaultHandler())
    return handle_request(h, req)
end

end