#include "video_metadata.h"

#include <flutter_linux/flutter_linux.h>
#include <gst/gst.h>
#include <gst/pbutils/pbutils.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string>
#include <ctime>

namespace pro_video_editor {

FlMethodResponse* HandleGetMetadata(FlValue* args) {
    FlValue* inputPathValue = fl_value_lookup_string(args, "inputPath");
    if (!inputPathValue || fl_value_get_type(inputPathValue) != FL_VALUE_TYPE_STRING) {
        return FL_METHOD_RESPONSE(fl_method_error_response_new(
            "InvalidArgument", "Missing or invalid inputPath", nullptr));
    }

    std::string inputPath = fl_value_get_string(inputPathValue);

    struct stat file_stat;
    int64_t fileSize = 0;
    std::string dateStr;
    if (stat(inputPath.c_str(), &file_stat) == 0) {
        fileSize = file_stat.st_size;
        char buffer[64];
        std::tm* tm = std::localtime(&file_stat.st_ctime);
        std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", tm);
        dateStr = buffer;
    } else {
        return FL_METHOD_RESPONSE(fl_method_error_response_new(
            "FileError", "Failed to stat file", nullptr));
    }

    gst_init(nullptr, nullptr);

    GstDiscoverer* discoverer = gst_discoverer_new(5 * GST_SECOND, nullptr);
    if (!discoverer) {
        return FL_METHOD_RESPONSE(fl_method_error_response_new(
            "GStreamerError", "Failed to create discoverer", nullptr));
    }

    std::string uri = "file://" + inputPath;
    GstDiscovererInfo* info = gst_discoverer_discover_uri(discoverer, uri.c_str(), nullptr);

    if (!info) {
        g_object_unref(discoverer);
        return FL_METHOD_RESPONSE(fl_method_error_response_new(
            "GStreamerError", "Failed to get metadata", nullptr));
    }

    GstDiscovererStreamInfo* streamInfo = gst_discoverer_info_get_stream_info(info);
    GstCaps* caps = gst_discoverer_stream_info_get_caps(streamInfo);

    int width = 0, height = 0, rotation = 0;
    double duration_ms = 0.0;
    int bitrate = 0;

    if (caps) {
        const GstStructure* s = gst_caps_get_structure(caps, 0);
        gst_structure_get_int(s, "width", &width);
        gst_structure_get_int(s, "height", &height);
    }

    gint64 duration_ns = gst_discoverer_info_get_duration(info);
    duration_ms = static_cast<double>(duration_ns) / GST_MSECOND;

    if (duration_ms > 0.0) {
        bitrate = static_cast<int>((fileSize * 8) / (duration_ms / 1000.0));
    }

    const GstTagList* tags = gst_discoverer_info_get_tags(info);
    gchar* title = nullptr;
    if (tags) {
        gst_tag_list_get_string(tags, GST_TAG_TITLE, &title);
    }

    g_autoptr(FlValue) result_map = fl_value_new_map();
    fl_value_set_string_take(result_map, "fileSize", fl_value_new_int(fileSize));
    fl_value_set_string_take(result_map, "duration", fl_value_new_float(duration_ms));
    fl_value_set_string_take(result_map, "width", fl_value_new_int(width));
    fl_value_set_string_take(result_map, "height", fl_value_new_int(height));
    fl_value_set_string_take(result_map, "rotation", fl_value_new_int(rotation));
    fl_value_set_string_take(result_map, "bitrate", fl_value_new_int(bitrate));
    fl_value_set_string_take(result_map, "title", fl_value_new_string(title ? title : ""));
    fl_value_set_string_take(result_map, "artist", fl_value_new_string(""));
    fl_value_set_string_take(result_map, "author", fl_value_new_string(""));
    fl_value_set_string_take(result_map, "album", fl_value_new_string(""));
    fl_value_set_string_take(result_map, "albumArtist", fl_value_new_string(""));
    fl_value_set_string_take(result_map, "date", fl_value_new_string(dateStr.c_str()));

    if (title) g_free(title);
    gst_discoverer_info_unref(info);
    g_object_unref(discoverer);

    return FL_METHOD_RESPONSE(fl_method_success_response_new(result_map));
}

}  // namespace pro_video_editor
