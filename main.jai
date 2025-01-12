main :: () {
    #if OS == .WINDOWS {
        Windows :: #import "Windows";
        Windows.SetProcessDPIAware();
        Windows.timeBeginPeriod(1);
    }

    window = create_window(window_width, window_height, "RSS Reader");
    window_width, window_height = Simp.get_render_dimensions(window);
    Simp.prepare_window(window, 8);
    Simp.set_render_target(window, .LEFT_HANDED);

    init_fonts();
    ui_init();

    read_config_file();

    init_networker();

    for config.feeds {
        success := fetch(it.url);
        if !success  fatal("fetch");
    }

    results := 0;

    quit := false;
    while !quit {
        current_time = seconds_since_init();

        if screen == .Loading {
            completed, success := get_completed();
            if !success  break;

            for completed {
                feed := get_feed(it.url);
                assert(feed != null);

                root, result := xml_parse(it.message);
                if result.status != .ok  fatal("xml_parse");
                // defer xml_free(root);

                for root {
                    if it.type == .element && it.name == "item" {
                        article: Article;

                        for it {
                            if it.type == .element {
                                if it.name == {
                                    case "title";
                                        if it.first_child.type != .pcdata {
                                            article.title = "---";
                                        } else {
                                            article.title = copy_string(it.first_child.value);
                                        }
                                    case "link";
                                        if it.first_child.type != .pcdata {
                                            article.url = "---";
                                        } else {
                                            article.url = copy_string(it.first_child.value);
                                        }
                                    case "pubDate";
                                        if it.first_child.type != .pcdata {
                                            article.date = "---";
                                        } else {
                                            article.date = copy_string(it.first_child.value);
                                        }
                                    case "description";
                                        if it.first_child.type != .pcdata {
                                            article.description = "---";
                                        } else {
                                            article.description = copy_string(it.first_child.value);
                                        }
                                }
                            }
                        }

                        array_add(*feed.articles, article);
                    }
                }

                results += 1;
                if results == config.feeds.count  screen = .Main;
            }
        }

        Input.update_window_events();
        for Input.get_window_resizes() {
            Simp.update_window(it.window);

            if it.window == window {
                window_width = it.width;
                window_height = it.height;
            }
        }

        for Input.events_this_frame {
            if it.type == .QUIT  quit = true;

            getrect_handle_event(it);
        }

        draw_one_frame();

        reset_temporary_storage();
    }

    // deinit_networker();

    report_memory_leaks();
}

init_fonts :: () {
    path := path_strip_filename(get_path_of_running_executable());
    set_working_directory(path);

    pixel_height := 14;
    font = Simp.get_font_at_size(".", "fonts/FiraCode-Retina.ttf", pixel_height);
    assert(font != null);
}

read_config_file :: () {
    handler: Text_File_Handler;
    defer deinit(*handler);

    found, exe_path, exe_name := split_from_right(get_path_of_running_executable(), #char "/");
    if !found  fatal("Unable to find my own executable?!");

    filename := tprint("%/%", exe_path, "config.conf");

    short_name := "config";
    start_file(*handler, short_name, filename, false);
    if handler.failed  fatal("Unable to read config file");

    section := Config_Section.Unspecified;

    while true {
        line, found := consume_next_line(*handler);
        if !found  break;

        {
            if line == "[[feeds]]" {
                section = .Feeds;
            } else if section == .Feeds {
                if starts_with(trim_left(line), "//")  continue;

                found, name, url := split_from_left(line, "::");
                if !found  fatal(tprint("Could not parse line '%'", line));

                name = trim(name);
                url = trim(url);

                array_add(*config.feeds, Feed.{ name = name, url = url });
            } else {
                fatal(tprint("Could not parse line '%'", line));
            }
        }
    }
}

draw_one_frame :: () {
    Simp.clear_render_target(0, 0, 0, 1);

    ui_per_frame_update(window, window_width, window_height, current_time);

    rect := get_rect(0, 0, xx window_width, xx window_height);

    Simp.set_shader_for_color();

    if #complete screen == {
        case .Loading;
            text := "Loading...";

            color := Vector4.{1, 1, 1, 1};

            text_width := Simp.prepare_text(font, text);
            text_x := (rect.w - text_width) / 2;
            text_y := rect.h / 2 + font.character_height / 4;

            Simp.draw_prepared_text(font, xx text_x, xx text_y, color);

        case .Main;
            button_height :: 40;

            left, right := cut_left(rect, rect.w / 3);

            region, inside := begin_scrollable_region(left);
            s := inside;
            s.h = button_height;
            s.y -= feeds_scroll_value;

            for * config.feeds {
                pressed := button(s, it.name, identifier = it_index);
                if pressed  selected_feed = it;

                if it_index != config.feeds.count  s.y += floor(button_height * 1.1 + 0.5);
            }

            end_scrollable_region(region, s.x + s.w, s.y + s.h, *feeds_scroll_value);

            if selected_feed != null {
                region, inside := begin_scrollable_region(right);
                s := inside;
                s.h = button_height;
                s.y -= articles_scroll_value;

                for * selected_feed.articles {
                    pressed := button(s, it.title, identifier = it_index);
                    if pressed {
                        screen = .Article;
                        selected_article = it;
                    }

                    if it_index != selected_feed.articles.count  s.y += floor(button_height * 1.0 + 0.5);
                }

                end_scrollable_region(region, s.x + s.w, s.y + s.h, *articles_scroll_value);
            }

        case .Article;
            header, body := cut_top(rect, 60);
            back, title := cut_left(header, 120);
            open:, title = cut_right(title, 120);

            body.y += 20;
            body.h -= 20;

            pressed := button(back, "Back");
            if pressed  screen = .Main;

            pressed = button(open, "Open");
            if pressed  open_url(selected_article.url);

            color := Vector4.{1, 1, 1, 1};

            text_width := Simp.prepare_text(font, selected_article.title);
            text_x := title.x + (title.w - text_width) / 2;
            text_y := title.h / 2 + font.character_height / 4;

            Simp.draw_prepared_text(font, xx text_x, xx text_y, color);

            max_x_chars := cast(int) floor(body.w / font.x_advance);
            row := 0;
            while row * max_x_chars < selected_article.description.count {
                start := selected_article.description.data + row * max_x_chars;
                count := min(max_x_chars, selected_article.description.count - row * max_x_chars);
                text := string.{ data = start, count = count };

                Simp.draw_text(font, xx body.x, xx body.y + (font.character_height + 4) * row, text);

                row += 1;
            }
    }

    Simp.swap_buffers(window);
}

open_url :: (url: string) {
    run_command("explorer", url);
}

get_feed :: (url: string) -> *Feed {
    for * config.feeds {
        if it.url == url  return it;
    }

    return null;
}

print_feed :: (feed: Feed) {
    print("% (%)\n", feed.name, feed.url);

    for feed.articles {
        print("% - % (%)\n", it.title, it.date, it.url);
        print("  %\n", it.description);
    }

    print("\n");
}

fatal :: (message: string) {
    print("Fatal: %\n", message);
    exit(1);
}

Config_Section :: enum {
    Unspecified;
    Feeds;
}

Config :: struct {
    feeds: [..] Feed;
}

Article :: struct {
    title:       string;
    url:         string;
    date:        string;
    description: string;
}

Feed :: struct {
    name: string;
    url:  string;

    articles: [..] Article;
}

Screen :: enum {
    Loading;
    Main;
    Article;
}

config: Config;

window:        Window_Type;
window_width:  s32 = 1280;
window_height: s32 = 720;

font: *Simp.Dynamic_Font;

screen := Screen.Loading;

current_time: float64;

feeds_scroll_value:    float;
articles_scroll_value: float;

selected_feed:    *Feed;
selected_article: *Article;

#import "Basic"()(MEMORY_DEBUGGER = true, TEMP_ALLOCATOR_POISON_FREED_MEMORY = true);
#import "Curl"()(LINUX_USE_SYSTEM_LIBRARY = true);
#import "GetRect_LeftHanded";
#import "Hash_Table";
#import "Math";
#import "Process";
#import "String";
#import "System";
#import "Text_File_Handler";
#import "Window_Creation";
#import "XML";

Input :: #import "Input";
Simp :: #import "Simp";

#load "networker.jai";