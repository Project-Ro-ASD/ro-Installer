#ifndef SYSTEM_COMMAND_H
#define SYSTEM_COMMAND_H

#include <string>
#include <array>
#include <memory>
#include <stdexcept>
#include <iostream>

class SystemCommand {
public:
    struct CommandResult {
        int exit_code;
        std::string output;
        std::string error;
    };

    static CommandResult execute(const std::string& command) {
        CommandResult result;
        std::array<char, 128> buffer;
        std::string output;
        
        // redirect stderr to stdout so we can capture everything
        std::string cmd = command + " 2>&1";
        auto pipe = popen(cmd.c_str(), "r");
        
        if (!pipe) {
            result.exit_code = -1;
            result.error = "popen() failed for command: " + command;
            return result;
        }
        
        while (fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
            output += buffer.data();
        }
        
        result.exit_code = pclose(pipe);
        
        // pclose returns the exit status of the shell, need to extract actual exit code
        if (WIFEXITED(result.exit_code)) {
            result.exit_code = WEXITSTATUS(result.exit_code);
        }
        
        if (result.exit_code != 0) {
            result.error = output;
        } else {
            result.output = output;
        }
        
        return result;
    }
};

#endif // SYSTEM_COMMAND_H
