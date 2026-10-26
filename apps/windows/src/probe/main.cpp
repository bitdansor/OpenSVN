#include "opensvn/discovery.hpp"
#include "opensvn/error_mapper.hpp"
#include "opensvn/errors.hpp"
#include "opensvn/json_contract.hpp"
#include "opensvn/parsing.hpp"
#include "opensvn/text.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr const char* usage =
    "usage: opensvn-probe map-error --exit <code> [--stdout <file>] [--stderr <file>]\n"
    "       opensvn-probe discover [--explicit <svn.exe>] [--path <PATH>]\n"
    "       opensvn-probe parse-status <file>\n"
    "       opensvn-probe parse-log <file>\n"
    "       opensvn-probe parse-info <file>\n"
    "       opensvn-probe parse-properties <file>\n"
    "       opensvn-probe parse-preview <status-file>\n";

std::optional<std::string> value_after(const std::string& flag,
                                       const std::vector<std::string>& arguments) {
    for (std::size_t index = 0; index + 1 < arguments.size(); ++index) {
        if (arguments[index] == flag) return arguments[index + 1];
    }
    return std::nullopt;
}

std::string read_file(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot read " + opensvn::text::path_to_utf8(path));
    return std::string((std::istreambuf_iterator<char>(input)),
                       std::istreambuf_iterator<char>());
}

std::string read_stdin() {
    std::string data((std::istreambuf_iterator<char>(std::cin)),
                     std::istreambuf_iterator<char>());
    return data;
}

std::string flatten(std::string_view text) {
    std::string result(text);
    for (char& c : result) {
        if (c == '\r' || c == '\n') c = ' ';
    }
    return result;
}

void emit(const std::string& key, const std::string& value) {
    std::cout << key << "=" << flatten(value) << "\n";
}

int fail(const std::string& message, int code = 1) {
    std::cerr << "opensvn-probe: " << message << "\n";
    return code;
}

int map_error(const std::vector<std::string>& arguments) {
    const auto exit_text = value_after("--exit", arguments);
    if (!exit_text) return fail("--exit is required", 2);
    std::int32_t exit_code = 0;
    try {
        exit_code = static_cast<std::int32_t>(std::stol(*exit_text));
    } catch (...) {
        return fail("--exit expects an integer", 2);
    }
    const std::string standard_error =
        value_after("--stderr", arguments)
            ? read_file(opensvn::text::path_from_utf8(*value_after("--stderr", arguments)))
            : read_stdin();
    const std::string standard_output =
        value_after("--stdout", arguments)
            ? read_file(opensvn::text::path_from_utf8(*value_after("--stdout", arguments)))
            : std::string{};

    const opensvn::SVNError error =
        opensvn::SVNErrorMapper::error(exit_code, standard_error, standard_output);
    emit("code", error.identifier());
    emit("severity", std::string(opensvn::to_string(error.severity())));
    emit("svn", error.svn_code.value_or(""));
    emit("message", error.message);
    emit("remediation", std::string(opensvn::remediation(error.code)));
    return 0;
}

int discover(const std::vector<std::string>& arguments) {
    opensvn::SVNDiscovery discovery;
    if (const auto explicit_path = value_after("--explicit", arguments)) {
        discovery.explicit_executable = opensvn::text::path_from_utf8(*explicit_path);
    }
    if (const auto search_path = value_after("--path", arguments)) {
        discovery.environment["PATH"] = *search_path;
    }
    try {
        const opensvn::SVNInstallation installation = discovery.resolve();
        emit("source", std::string(opensvn::to_string(installation.source)));
        emit("path", opensvn::text::path_to_utf8(installation.executable));
        emit("version", installation.version.to_string());
        std::string searched;
        for (const auto& candidate : discovery.candidates()) {
            if (!searched.empty()) searched += ";";
            searched += opensvn::text::path_to_utf8(candidate.path);
        }
        emit("searched", searched);
        return 0;
    } catch (const opensvn::SVNException& error) {
        emit("source", "none");
        emit("error", error.error().message);
        emit("searched", error.error().diagnostic_output.value_or(""));
        return 1;
    }
}

int parse_document(const std::string& kind, const std::string& file) {
    const std::string xml = read_file(opensvn::text::path_from_utf8(file));
    opensvn::Json output;
    if (kind == "status") {
        output = opensvn::status_to_json(opensvn::parsing::parse_status(xml));
    } else if (kind == "log") {
        output = opensvn::log_to_json(opensvn::parsing::parse_log(xml));
    } else if (kind == "info") {
        output = opensvn::info_to_json(opensvn::parsing::parse_info(xml));
    } else if (kind == "properties") {
        output = opensvn::properties_to_json(opensvn::parsing::parse_properties(xml));
    } else if (kind == "preview") {
        output = opensvn::remote_preview_to_json(
            opensvn::RemotePreview::make(opensvn::parsing::parse_status(xml)));
    } else {
        return fail("unknown parse kind: " + kind, 2);
    }
    std::cout << output.dump(2) << "\n";
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    std::vector<std::string> arguments;
    for (int index = 1; index < argc; ++index) arguments.emplace_back(argv[index]);
    if (arguments.empty()) {
        std::cerr << usage;
        return 2;
    }

    const std::string command = arguments.front();
    try {
        if (command == "map-error") return map_error(arguments);
        if (command == "discover") return discover(arguments);
        if (command == "parse-status" && arguments.size() >= 2) {
            return parse_document("status", arguments[1]);
        }
        if (command == "parse-log" && arguments.size() >= 2) {
            return parse_document("log", arguments[1]);
        }
        if (command == "parse-info" && arguments.size() >= 2) {
            return parse_document("info", arguments[1]);
        }
        if (command == "parse-properties" && arguments.size() >= 2) {
            return parse_document("properties", arguments[1]);
        }
        if (command == "parse-preview" && arguments.size() >= 2) {
            return parse_document("preview", arguments[1]);
        }
        if (command == "--version") {
            std::cout << "0.1.0\n";
            return 0;
        }
        if (command == "--help" || command == "-h") {
            std::cout << usage;
            return 0;
        }
        std::cerr << usage;
        return 2;
    } catch (const opensvn::SVNException& error) {
        std::cerr << error.what() << "\n";
        return 1;
    } catch (const std::exception& error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
}
