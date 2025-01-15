completed_requests_lock: Mutex;
completed_requests: [..] Completed_Request;

init_networker :: () {
    multi_handle = curl_multi_init();

    init(*completed_requests_lock);
    init(*work_queue_lock);

    thread_init(*thread, worker_proc);
    thread_start(*thread);
}

deinit_networker :: () {
    work := New(Work);
    work.type = .Stop;

    lock(*work_queue_lock);
    array_add(*work_queue, work);
    unlock(*work_queue_lock);

    thread_deinit(*thread);

    for requests {
        assert(curl_multi_remove_handle(multi_handle, it.handle) == .OK);
        curl_easy_cleanup(it.handle);
    }

    curl_multi_cleanup(multi_handle);
}

get_completed :: () -> [] Completed_Request /* temporary storage */ {
    completed: [..] Completed_Request;
    completed.allocator = temp;

    lock(*completed_requests_lock);
    for * completed_requests {
        c := Deep_Copy(it, .{},, temp);
        array_add(*completed, c);

        free(it.url.data);
        free(it.message.data);
        deinit(*it.headers);

        remove it;
    }
    unlock(*completed_requests_lock);

    return completed;
}

fetch :: (url: string) {
    fail :: () #expand {
        curl_easy_cleanup(`request.handle);
        `return false;
    }

    work := New(Work);
    work.type = .Fetch;
    work.url = copy_string(url);

    lock(*work_queue_lock);
    array_add(*work_queue, work);
    unlock(*work_queue_lock);
}

#scope_file

worker_proc :: (thread: *Thread) -> s64 {
    quit := false;
    while !quit {
        lock(*work_queue_lock);
        for work_queue {
            if it.type == .Stop {
                quit = true;
                break;
            }

            request := array_add(*requests);
            request.url = it.url;
            request.handle = curl_easy_init();

            curl_easy_setopt(request.handle, .URL, temp_c_string(it.url));
            curl_easy_setopt(request.handle, .HEADERFUNCTION, header_callback);
            curl_easy_setopt(request.handle, .HEADERDATA, *request.header_builder);
            curl_easy_setopt(request.handle, .WRITEFUNCTION, write_callback);
            curl_easy_setopt(request.handle, .WRITEDATA, *request.body_builder);

            //curl_easy_setopt(request.handle, .VERBOSE, 1);

            // TODO: I am not sure why but curl always fails SSL certificate verification.
            curl_easy_setopt(request.handle, .SSL_VERIFYHOST, 0);
            curl_easy_setopt(request.handle, .SSL_VERIFYPEER, 0);

            curl_multi_add_handle(multi_handle, request.handle);

            free(it);

            remove it;
        }
        unlock(*work_queue_lock);

        if quit  break;

        remaining: s32;
        curl_multi_perform(multi_handle, *remaining);
        curl_multi_poll(multi_handle, null, 0, 1000, null);

        lock(*completed_requests_lock);
        while true {
            message := curl_multi_info_read(multi_handle, *remaining);
            if message == null  break;

            if message.msg == .DONE {
                for requests {
                    if it.handle == message.easy_handle {
                        curl_multi_remove_handle(multi_handle, it.handle);
                        curl_easy_cleanup(it.handle);

                        completed_request: Completed_Request = ---;
                        completed_request.success = message.data.result == .OK;
                        completed_request.url = it.url;
                        completed_request.message = builder_to_string(*it.body_builder);
                        completed_request.headers = parse_headers(builder_to_string(*it.header_builder,, temp));

                        array_add(*completed_requests, completed_request);

                        free_buffers(*it.body_builder);
                        free_buffers(*it.header_builder);

                        remove it;
                    }
                }
            }
        }
        unlock(*completed_requests_lock);

        // TODO: We don't need to run this loop if we don't have any work to do.
    }

    return 0;
}

header_callback :: (ptr: *u8, size: u64, nmemb: u64, userdata: *void) -> u64 #c_call {
    headers_builder := cast(*String_Builder)userdata;

    push_context {
        header: string = ---;
        header.data = ptr;
        header.count = xx nmemb;

        // when using .FOLLOWLOCATION, we have to clear old headers after redirecting
        // we know all our headers are expired if we receive a new HTTP status "header"
        if begins_with(header, "HTTP/") {
            reset(headers_builder);
            return nmemb;
        }

        append(headers_builder, ptr, xx nmemb);
    }

    return nmemb;
}

parse_headers :: (headers: string) -> headers_table: Table(string, string) /* temporary storage */ {
    headers_table: Table(string, string);
    headers_table.allocator = temp;
    init(*headers_table);

    if !headers return headers_table;

    startofline := 0;
    for i: 0 .. headers.count-1 -3/*because we're looking 3 ahead*/ {
        if headers[i] == #char "\r" && headers[i+1] == #char "\n" {
            defer startofline = i + 2;

            header: string = ---;
            header.data = headers.data + startofline;
            header.count = i - startofline;

            if begins_with(header, "HTTP/") continue; // first line is the status code. not a header

            found, key, val := split_from_left(header, ": ");
            if !found break; // parse error
            table_add(*headers_table, key, val);

            if headers[i+2] == #char "\r" && headers[i+3] == #char "\n" {
                break; // \r\n\r\n found. end of headers
            }
        }
    }

    return headers_table;
}

write_callback :: (ptr: *u8, size: u64, nmemb: u64, userdata: *void) -> u64 #c_call {
    body_builder := cast(*String_Builder)userdata;

    push_context {
        append(body_builder, ptr, xx nmemb);
    }

    return nmemb;
}

Completed_Request :: struct {
    success: bool;
    url:     string;
    message: string;
    headers: Table(string, string);
    headers.allocator = temp;
}

Request :: struct {
    handle:  *CURL;
    url:     string;
    body_builder:   String_Builder;
    header_builder: String_Builder;
}

Work_Type :: enum {
    Stop;
    Fetch;
}

Work :: struct {
    type: Work_Type;
    union {
        url: string;
    }
}

multi_handle: *CURL;

requests: [..] Request;

thread: Thread;

work_queue_lock: Mutex;
work_queue:      [..] *Work;