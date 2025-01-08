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
                    completed_request.url = it.url;
                    completed_request.message = builder_to_string(*it.builder,, temp);
                    array_add(*completed, completed_request);

                    free_buffers(*it.builder);

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

    if curl_easy_setopt(request.handle, .URL, temp_c_string(url))       != .OK  fail();
    if curl_easy_setopt(request.handle, .WRITEFUNCTION, write_callback) != .OK  fail();
    if curl_easy_setopt(request.handle, .WRITEDATA, *request.builder)   != .OK  fail();

    if curl_multi_add_handle(multi_handle, request.handle) != .OK  fail();

    remaining: s32;
    if curl_multi_perform(multi_handle, *remaining) != .OK  fail();

    return true;
}

write_callback :: (ptr: *u8, size: u64, nmemb: u64, userdata: *void) -> u64 #c_call {
    body_builder := cast(*String_Builder)userdata;

    push_context {
        append(body_builder, ptr, xx nmemb);
    }

    return nmemb;
}

Completed_Request :: struct {
    url:     string;
    message: string;
}

Request :: struct {
    handle:  *CURL;
    url:     string;
    builder: String_Builder;
}

multi_handle: *CURL;
requests:     [..] Request;