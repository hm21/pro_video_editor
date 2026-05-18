#include "thumbnail_generator.h"

#include <flutter_linux/flutter_linux.h>

#include <fstream>
#include <string>
#include <vector>
#include <sstream>
#include <chrono>
#include <filesystem>
#include <future>
#include <cstdlib>
#include <iomanip>
#include <cmath>

namespace fs = std::filesystem;
namespace pro_video_editor {

static std::string GenerateTempFilename(const std::string& prefix, const std::string& extension) {
    std::stringstream filename;
    auto now = std::chrono::system_clock::now();
    auto time = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;

    std::tm tm = *std::localtime(&time);
    filename << "/tmp/" << prefix << "_"
             << std::put_time(&tm, "%Y%m%d%H%M%S")
             << ms.count() << extension;

    return filename.str();
}

static bool WriteBytesToFile(const std::string& path, const uint8_t* data, size_t size) {
    std::ofstream out(path, std::ios::binary);
    if (!out.is_open()) return false;
    out.write(reinterpret_cast<const char*>(data), size);
    return true;
}

FlMethodResponse* HandleGenerateThumbnails(FlValue* args) {
    FlValue* videoBytesVal  = fl_value_lookup_string(args, "videoBytes");
    FlValue* timestampsVal  = fl_value_lookup_string(args, "timestamps");
    FlValue* formatVal      = fl_value_lookup_string(args, "thumbnailFormat");
    FlValue* extensionVal   = fl_value_lookup_string(args, "extension");
    FlValue* widthVal       = fl_value_lookup_string(args, "imageWidth");

    if (!videoBytesVal || fl_value_get_type(videoBytesVal) != FL_VALUE_TYPE_UINT8_LIST ||
        !timestampsVal || fl_value_get_type(timestampsVal) != FL_VALUE_TYPE_LIST ||
        !formatVal    || fl_value_get_type(formatVal)    != FL_VALUE_TYPE_STRING ||
        !extensionVal || fl_value_get_type(extensionVal) != FL_VALUE_TYPE_STRING ||
        !widthVal) {
        return FL_METHOD_RESPONSE(fl_method_error_response_new(
            "InvalidArgument", "Missing required parameters", nullptr));
    }

    const uint8_t* videoData     = fl_value_get_uint8_list(videoBytesVal);
    size_t         videoDataSize = fl_value_get_length(videoBytesVal);

    double widthDouble = 0.0;
    if (fl_value_get_type(widthVal) == FL_VALUE_TYPE_FLOAT) {
        widthDouble = fl_value_get_float(widthVal);
    } else if (fl_value_get_type(widthVal) == FL_VALUE_TYPE_INT) {
        widthDouble = static_cast<double>(fl_value_get_int(widthVal));
    }
    int roundedWidth = static_cast<int>(std::round(widthDouble));

    std::string videoExt = fl_value_get_string(extensionVal);
    if (videoExt.empty() || videoExt[0] != '.') videoExt = "." + videoExt;

    std::string imageExt = fl_value_get_string(formatVal);
    if (imageExt.empty() || imageExt[0] != '.') imageExt = "." + imageExt;

    std::string tempVideoPath = GenerateTempFilename("video_temp", videoExt);
    if (!WriteBytesToFile(tempVideoPath, videoData, videoDataSize)) {
        return FL_METHOD_RESPONSE(fl_method_error_response_new(
            "FileError", "Failed to write temp video file", nullptr));
    }

    std::string ffmpegPath = "ffmpeg";
    size_t count = fl_value_get_length(timestampsVal);
    std::vector<std::future<void>> futures;
    std::vector<std::vector<uint8_t>> thumbnails(count);

    for (size_t i = 0; i < count; i++) {
        FlValue* tsVal = fl_value_get_list_value(timestampsVal, i);
        if (!tsVal || fl_value_get_type(tsVal) != FL_VALUE_TYPE_INT) {
            continue;
        }

        size_t currentIndex = i;
        double tsSec = static_cast<double>(fl_value_get_int(tsVal)) / 1000.0;

        futures.push_back(std::async(std::launch::async, [=, &thumbnails]() {
            std::ostringstream timestampStream;
            timestampStream << std::fixed << std::setprecision(3) << tsSec;

            std::string tempImagePath = GenerateTempFilename(
                "thumb_" + std::to_string(currentIndex), imageExt);

            std::ostringstream cmd;
            cmd << ffmpegPath
                << " -ss " << timestampStream.str()
                << " -i \"" << tempVideoPath << "\""
                << " -vframes 1 -vf scale=" << roundedWidth << ":-2"
                << " \"" << tempImagePath << "\"";

            int retCode = std::system(cmd.str().c_str());

            if (retCode == 0 && fs::exists(tempImagePath)) {
                std::ifstream in(tempImagePath, std::ios::binary);
                thumbnails[currentIndex] = std::vector<uint8_t>(
                    (std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
                std::remove(tempImagePath.c_str());
            }
        }));
    }

    for (auto& fut : futures) {
        fut.get();
    }

    std::remove(tempVideoPath.c_str());

    g_autoptr(FlValue) result_list = fl_value_new_list();
    for (size_t i = 0; i < count; i++) {
        if (!thumbnails[i].empty()) {
            fl_value_append_take(result_list,
                fl_value_new_uint8_list(thumbnails[i].data(), thumbnails[i].size()));
        } else {
            fl_value_append_take(result_list, fl_value_new_null());
        }
    }

    return FL_METHOD_RESPONSE(fl_method_success_response_new(result_list));
}

} // namespace pro_video_editor
