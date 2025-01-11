init_networker :: () {
    multi_handle = curl_multi_init();
}

deinit_networker :: () {
    for requests {
        assert(curl_multi_remove_handle(multi_handle, it.handle) == .OK);
        curl_easy_cleanup(it.handle);
    }

    curl_multi_cleanup(multi_handle);
}

get_completed :: () -> [] Completed_Request /* temporary storage */, success: bool #must {
    fail :: () #expand {
        `return .[], false;
    }

    remaining: s32;
    if curl_multi_perform(multi_handle, *remaining)       != .OK  fail();
    if curl_multi_poll(multi_handle, null, 0, 1000, null) != .OK  fail();

    completed: [..] Completed_Request;
    completed.allocator = temp;

    while true {
        message := curl_multi_info_read(multi_handle, *remaining);
        if message == null  break;

        if message.msg == .DONE {
            for requests {
                if it.handle == message.easy_handle {
                    assert(curl_multi_remove_handle(multi_handle, it.handle) == .OK);

                    curl_easy_cleanup(it.handle);

                    completed_request: Completed_Request = ---;
                    completed_request.success = message.data.result == .OK;
                    completed_request.url = it.url;
                    completed_request.message = builder_to_string(*it.body_builder,, temp);
                    completed_request.headers = parse_headers(builder_to_string(*it.header_builder,, temp));
                    array_add(*completed, completed_request);

                    free_buffers(*it.body_builder);

                    remove it;
                }
            }
        }
    }

    return completed, true;
}

fetch :: (url: string) -> success: bool #must {
    fail :: () #expand {
        curl_easy_cleanup(`request.handle);
        `return false;
    }

    request := array_add(*requests);

    request.url = url;
    request.handle = curl_easy_init();

    if curl_easy_setopt(request.handle, .URL, temp_c_string(url))             != .OK  fail();
    if curl_easy_setopt(request.handle, .HEADERFUNCTION, header_callback)     != .OK  fail();
    if curl_easy_setopt(request.handle, .HEADERDATA, *request.header_builder) != .OK  fail();
    if curl_easy_setopt(request.handle, .WRITEFUNCTION, write_callback)       != .OK  fail();
    if curl_easy_setopt(request.handle, .WRITEDATA, *request.body_builder)    != .OK  fail();

    // TODO: I am not sure why but curl always fail SSL certificate verification.
    if curl_easy_setopt(request.handle, .SSL_VERIFYHOST, 0) != .OK  fail();
    if curl_easy_setopt(request.handle, .SSL_VERIFYPEER, 0) != .OK  fail();

    if curl_multi_add_handle(multi_handle, request.handle) != .OK  fail();

    remaining: s32;
    if curl_multi_perform(multi_handle, *remaining) != .OK  fail();

    return true;
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

multi_handle: *CURL;
requests:     [..] Request;