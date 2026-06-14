#!/bin/bash

show_usage() {
    echo "Usage:"
    echo "  vsh -list server_name port"
    echo "  vsh -create server_name port archive_name [directory]"
    echo "  vsh -browse server_name port archive_name"
    echo "  vsh -extract server_name port archive_name"
}

# Communication avec le serveur 
send_command() {
    local server=$1
    local port=$2
    local command="$3"
    
    local request_file="/tmp/vsh_request_$port"
    local response_file="/tmp/vsh_response_$port"
    local ready_file="/tmp/vsh_response_$port.ready"
    
    echo "$command" > "$request_file"
    
    local timeout=50
    while [ $timeout -gt 0 ] && [ ! -f "$ready_file" ]; do
        sleep 0.1
        timeout=$((timeout - 1))
    done
    
    if [ -f "$ready_file" ]; then
        cat "$response_file" 2>/dev/null
        rm -f "$response_file" "$ready_file"
    else
        echo "ERROR: Server timeout"
        return 1
    fi
}

# Mode 1: List archives sur le serveur 
list_mode() {
    local server=$1
    local port=$2
    
    echo "Connecting to server $server:$port..."
    local response=$(send_command "$server" "$port" "LIST")
    
    if [ -n "$response" ]; then
        echo "Available archives:"
        echo "$response"
    else
        echo "Error: Could not connect to server"
        exit 1
    fi
}

# Mode 2: Create l'archive d'un repertoire ou re repertoire courant
create_mode() {
    local server=$1
    local port=$2
    local archive_name=$3
    local directory=${4:-.}  # Default to current directory if not specified
    
    if [ ! -d "$directory" ]; then
        echo "Error: Directory '$directory' does not exist"
        exit 1
    fi
    
    echo "Creating archive '$archive_name' from directory '$directory'..."
    
    local temp_archive=$(mktemp)
    local original_dir=$(pwd)
    
    # cd sur le repertoire sepcifie avent de creer
    cd "$directory" || { echo "Error: Cannot access directory '$directory'"; exit 1; }
    
    # generer archive
    generate_full_archive "." "$temp_archive"
    
    # retourner a repertoire initial
    cd "$original_dir"
    
    # envoie requete au serveur avec get 
    local request_file="/tmp/vsh_request_$port"
    local response_file="/tmp/vsh_response_$port"
    local ready_file="/tmp/vsh_response_$port.ready"
    
    # ecrire Create archive
    {
        echo "CREATE $archive_name"
        cat "$temp_archive"
    } > "$request_file"
    
    # attend for response
    local timeout=50
    while [ $timeout -gt 0 ] && [ ! -f "$ready_file" ]; do
        sleep 0.1
        timeout=$((timeout - 1))
    done
    
    if [ -f "$ready_file" ]; then
        local response=$(cat "$response_file" 2>/dev/null)
        rm -f "$response_file" "$ready_file"
        if [[ "$response" == "ERROR:"* ]]; then
            echo "Error: $response"
            exit 1
        else
            echo "Archive '$archive_name' created successfully"
        fi
    else
        echo "Error: Server timeout"
        exit 1
    fi
    
    rm -f "$temp_archive"
}

# generer archive
generate_full_archive() {
    local dir="$1"
    local output_file="$2"
    
    local temp_header=$(mktemp)
    local temp_body=$(mktemp)
    
    local current_body_line=1
    
    generate_directory_header "$dir" "Exemple\Test\\" "$temp_header" "$temp_body" "$current_body_line"
    
    local header_lines=$(wc -l < "$temp_header")
    local body_start=$((header_lines + 2))
    
    echo "2:$body_start" > "$output_file"
    cat "$temp_header" >> "$output_file"
    cat "$temp_body" >> "$output_file"
    
    rm -f "$temp_header" "$temp_body"
}

# Generate directory header recursively
generate_directory_header() {
    local dir="$1"
    local prefix="$2"
    local header_file="$3"
    local body_file="$4"
    local body_line_num="$5"
    
    echo "directory $prefix" >> "$header_file"
    
    while IFS= read -r -d '' subdir; do
        local dirname=$(basename "$subdir")
        local perms=$(stat -c "%A" "$subdir" 2>/dev/null || echo "drwxr-xr-x")
        local size=$(stat -c "%s" "$subdir" 2>/dev/null || echo "4096")
        echo "$dirname $perms $size" >> "$header_file"
    done < <(find "$dir" -maxdepth 1 -type d ! -path "$dir" -print0 | sort -z)
    
    while IFS= read -r -d '' file; do
        local filename=$(basename "$file")
        local perms=$(stat -c "%A" "$file" 2>/dev/null || echo "-rw-r--r--")
        local size=$(stat -c "%s" "$file" 2>/dev/null || wc -c < "$file" 2>/dev/null || echo "0")
        
        if [ "$size" -gt 0 ]; then
            local line_count=$(wc -l < "$file" 2>/dev/null || echo "0")
            if [ "$line_count" -eq 0 ] && [ "$size" -gt 0 ]; then
                line_count=1
            fi
            echo "$filename $perms $size $body_line_num $line_count" >> "$header_file"
            cat "$file" >> "$body_file"
            body_line_num=$((body_line_num + line_count))
        else
            echo "$filename $perms $size" >> "$header_file"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)
    
    echo "@" >> "$header_file"
    
    while IFS= read -r -d '' subdir; do
        local dirname=$(basename "$subdir")
        body_line_num=$(generate_directory_header "$subdir" "$prefix$dirname\\" "$header_file" "$body_file" "$body_line_num")
    done < <(find "$dir" -maxdepth 1 -type d ! -path "$dir" -print0 | sort -z)
    
    echo "$body_line_num"
}

# Mode 4: Extract archive to current directory  
extract_mode() {
    local server=$1
    local port=$2
    local archive_name=$3
    
    local output_dir="$4"
    echo "Extracting archive '$archive_name' to current directory..."
    if [ -n "$output_dir" ]; then
        mkdir -p "$output_dir"
        cd "$output_dir" || exit 1
    fi
    
    local response=$(send_command "$server" "$port" "GET $archive_name")
    
    if [[ "$response" == "ERROR:"* ]]; then
        echo "Error: Could not retrieve archive '$archive_name'"
        exit 1
    fi
    
    local temp_archive=$(mktemp)
    echo "$response" > "$temp_archive"
    
    local first_line=$(head -n 1 "$temp_archive")
    local body_start=$(echo "$first_line" | cut -d: -f2)
    local header_end=$((body_start - 1))
    sed -n "2,${header_end}p" "$temp_archive" > /tmp/vsh_header
    sed -n "${body_start},\$p" "$temp_archive" > /tmp/vsh_body
    
    local current_dir=""
    while IFS= read -r line; do
        if [[ "$line" == directory* ]]; then
            current_dir=$(echo "$line" | cut -d' ' -f2-)
        elif [ "$line" = "@" ]; then
            continue
        elif [ -n "$line" ]; then
            local parts=($line)
            local name="${parts[0]}"
            local perms="${parts[1]}"
            local size="${parts[2]}"
            
            local full_path
            if [ "$current_dir" = "Exemple\Test\\" ]; then
                full_path="$name"
            else
                local dir_path="${current_dir//\\/\/}"
                dir_path="${dir_path#Exemple/Test/}"
                if [ -n "$dir_path" ]; then
                    mkdir -p "$dir_path"
                    full_path="$dir_path/$name"
                else
                    full_path="$name"
                fi
            fi
            if [[ "$perms" == d* ]]; then
                mkdir -p "$full_path"
                convert_and_set_permissions "$perms" "$full_path"
            else
                if [ ${#parts[@]} -gt 3 ]; then
                    local start_line="${parts[3]}"
                    local line_count="${parts[4]}"
                    sed -n "${start_line},$((start_line + line_count - 1))p" /tmp/vsh_body > "$full_path"
                else
                    touch "$full_path"
                fi
                
                convert_and_set_permissions "$perms" "$full_path"
            fi
        fi
    done < /tmp/vsh_header
    
    rm -f "$temp_archive" /tmp/vsh_header /tmp/vsh_body
    echo "Archive extracted successfully"
}

add_file_to_archive() {
    local filename="$1"
    local perms="$2"
    local size="$3"
    local content="$4"
    
    local temp_header=$(mktemp)
    local added=0
    local in_current_dir=""
    
    while IFS= read -r line; do
        if [[ "$line" == directory* ]]; then
            local dir_path=$(echo "$line" | cut -d' ' -f2-)
            local dir_clean="${dir_path%\\}"
            local current_clean="${current_path%\\}"
            if [ "$dir_clean" = "$current_clean" ]; then
                in_current_dir="true"
                echo "$line" >> "$temp_header"
            else
                if [ "$in_current_dir" = "true" ] && [ $added -eq 0 ]; then
                    echo "$filename $perms $size" >> "$temp_header"
                    added=1
                fi
                in_current_dir=""
                echo "$line" >> "$temp_header"
            fi
        elif [ "$in_current_dir" = "true" ] && [ "$line" = "@" ]; then
            if [ $added -eq 0 ]; then
                echo "$filename $perms $size" >> "$temp_header"
                added=1
            fi
            echo "$line" >> "$temp_header"
            in_current_dir=""
        else
            echo "$line" >> "$temp_header"
        fi
    done < /tmp/vsh_header
    
    mv "$temp_header" /tmp/vsh_header
}

add_directory_to_archive() {
    local dir_path="$1"
    local perms="$2"
    local size="$3"
    
    local parent_path="$current_path"
    local dir_name="${dir_path#$parent_path}"
    if [[ "$dir_name" == "$dir_path" ]]; then
        local temp="${dir_path%\\}"
        dir_name="${temp##*\\}"
    fi
    dir_name="${dir_name//\\/}"
    
    local temp_header=$(mktemp)
    local added=0
    local in_current_dir=""
    
    while IFS= read -r line; do
        if [[ "$line" == directory* ]]; then
            local path=$(echo "$line" | cut -d' ' -f2-)
            local path_clean="${path%\\}"
            local current_clean="${current_path%\\}"
            if [ "$path_clean" = "$current_clean" ]; then
                in_current_dir="true"
                echo "$line" >> "$temp_header"
            else
                if [ "$in_current_dir" = "true" ] && [ $added -eq 0 ]; then
                    echo "$dir_name $perms $size" >> "$temp_header"
                    added=1
                fi
                in_current_dir=""
                echo "$line" >> "$temp_header"
            fi
        elif [ "$in_current_dir" = "true" ] && [ "$line" = "@" ]; then
            if [ $added -eq 0 ]; then
                echo "$dir_name $perms $size" >> "$temp_header"
                added=1
            fi
            echo "$line" >> "$temp_header"
            echo "directory ${dir_path}" >> "$temp_header"
            echo "@" >> "$temp_header"
            in_current_dir=""
        else
            echo "$line" >> "$temp_header"
        fi
    done < /tmp/vsh_header
    
    mv "$temp_header" /tmp/vsh_header
}

remove_from_archive() {
    local target="$1"
    local is_dir="$2"
    
    local temp_header=$(mktemp)
    local temp_body=$(mktemp)
    local in_current_dir=""
    local skip_dir=""
    
    if [ $is_dir -eq 1 ]; then
        local target_dir_path="${current_path}${target}\\\\"
    fi
    
    while IFS= read -r line; do
        if [[ "$line" == directory* ]]; then
            local dir_path=$(echo "$line" | cut -d' ' -f2-)
            
            if [ $is_dir -eq 1 ]; then
                if [[ "$dir_path" == "$target_dir_path"* ]]; then
                    skip_dir="true"
                    continue
                else
                    skip_dir=""
                fi
            fi
            
            local dir_clean="${dir_path%\\}"
            local current_clean="${current_path%\\}"
            if [ "$dir_clean" = "$current_clean" ]; then
                in_current_dir="true"
            else
                in_current_dir=""
            fi
            
            if [ "$skip_dir" != "true" ]; then
                echo "$line" >> "$temp_header"
            fi
        elif [ "$line" = "@" ]; then
            if [ "$skip_dir" = "true" ]; then
                skip_dir=""
                continue
            fi
            echo "$line" >> "$temp_header"
            in_current_dir=""
        elif [ "$in_current_dir" = "true" ]; then
            if [[ "$line" == "$target "* ]]; then
                continue
            else
                echo "$line" >> "$temp_header"
            fi
        else
            if [ "$skip_dir" != "true" ]; then
                echo "$line" >> "$temp_header"
            fi
        fi
    done < /tmp/vsh_header
    
    cp /tmp/vsh_body "$temp_body"
    
    mv "$temp_header" /tmp/vsh_header
    mv "$temp_body" /tmp/vsh_body
}

rebuild_archive() {
    local output_file="$1"
    
    local header_lines=$(wc -l < /tmp/vsh_header)
    local body_start=$((header_lines + 2))
    
    echo "2:$body_start" > "$output_file"
    cat /tmp/vsh_header >> "$output_file"
    cat /tmp/vsh_body >> "$output_file"
}

save_archive_to_server() {
    local archive_name="$1"
    
    local temp_archive=$(mktemp)
    rebuild_archive "$temp_archive"
    
    # Send UPDATE command to server
    local request_file="/tmp/vsh_request_$port"
    local response_file="/tmp/vsh_response_$port"
    local ready_file="/tmp/vsh_response_$port.ready"
    
    {
        echo "UPDATE $archive_name"
        cat "$temp_archive"
    } > "$request_file"
    
    local timeout=50
    while [ $timeout -gt 0 ] && [ ! -f "$ready_file" ]; do
        sleep 0.1
        timeout=$((timeout - 1))
    done
    
    if [ -f "$ready_file" ]; then
        local response=$(cat "$response_file" 2>/dev/null)
        rm -f "$response_file" "$ready_file"
        if [[ "$response" == "ERROR:"* ]]; then
            echo "Error saving archive: $response"
        fi
    fi
    
    rm -f "$temp_archive"
}

# Convert archive permissions 
convert_and_set_permissions() {
    local perms="$1"
    local filepath="$2"
    
    local perm_string="${perms:1}"
    
    local user_perms=0
    local group_perms=0
    local other_perms=0
    
    [[ "${perm_string:0:1}" == "r" ]] && user_perms=$((user_perms + 4))
    [[ "${perm_string:1:1}" == "w" ]] && user_perms=$((user_perms + 2))
    [[ "${perm_string:2:1}" == "x" ]] && user_perms=$((user_perms + 1))
    
    [[ "${perm_string:3:1}" == "r" ]] && group_perms=$((group_perms + 4))
    [[ "${perm_string:4:1}" == "w" ]] && group_perms=$((group_perms + 2))
    [[ "${perm_string:5:1}" == "x" ]] && group_perms=$((group_perms + 1))
    
    [[ "${perm_string:6:1}" == "r" ]] && other_perms=$((other_perms + 4))
    [[ "${perm_string:7:1}" == "w" ]] && other_perms=$((other_perms + 2))
    [[ "${perm_string:8:1}" == "x" ]] && other_perms=$((other_perms + 1))
    
    # Apply permissions
    chmod "$user_perms$group_perms$other_perms" "$filepath" 2>/dev/null || true
}

# Browse mode commands
cmd_ls() {
    local options="$1"
    local target="${2:-}"
    local list_path="$current_path"
    
    if [ -n "$target" ]; then
        if [[ "$target" == "\\"* ]] || [[ "$target" == "Exemple\\\\"* ]]; then
            # Absolute path
            if [[ "$target" == "\\"* ]]; then
                list_path="Exemple\Test\${target:1}\\"
            else
                list_path="$target\\"
            fi
        else
            # Relative path
            list_path="$current_path$target\\"
        fi
    elif [[ "$options" != -* ]] && [ -n "$options" ]; then
        target="$options"
        options=""
        if [[ "$target" == "\\"* ]] || [[ "$target" == "Exemple\\\\"* ]]; then
            if [[ "$target" == "\\"* ]]; then
                list_path="Exemple\Test\${target:1}\\"
            else
                list_path="$target\\"
            fi
        else
            list_path="$current_path$target\\"
        fi
    fi
    
    local in_current_dir=""
    local search_dir="${list_path%\\}"
    
    while IFS= read -r line; do
        if [[ "$line" == directory* ]]; then
            local dir_path=$(echo "$line" | cut -d' ' -f2-)
            local dir_path_clean="${dir_path%\\}"
            if [ "$dir_path_clean" = "$search_dir" ]; then
                in_current_dir="true"
            else
                in_current_dir=""
            fi
        elif [ "$in_current_dir" = "true" ]; then
            if [ "$line" = "@" ]; then
                break
            elif [ -n "$line" ]; then
                local parts=($line)
                local name="${parts[0]}"
                local perms="${parts[1]}"
                local size="${parts[2]}"
                
                if [[ "$options" != *"a"* ]] && [[ "$name" == .* ]]; then
                    continue
                fi
                
                if [[ "$options" == *"-l"* ]]; then
                    echo "$perms $size $name"
                else
                    if [[ "$perms" == d* ]]; then
                        echo -n "$name\\\\ "
                    elif [[ "$perms" == *x* ]]; then
                        echo -n "$name* "
                    else
                        echo -n "$name "
                    fi
                fi
            fi
        fi
    done < /tmp/vsh_header
    
    if [[ "$options" != *"-l"* ]]; then
        echo
    fi
}

cmd_cd() {
    local target="$1"
    
    case "$target" in
        "\\"|"/"|"")
            current_path="Exemple\Test\\"
            ;;
        "..")
            if [ "$current_path" != "Exemple\Test\\" ]; then
                local temp="${current_path%\\}"
                current_path="${temp%\\*}\\"
            fi
            ;;
        *)
            local new_path
            if [[ "$target" == "\\"* ]] || [[ "$target" == "Exemple\\\\"* ]]; then
                # Absolute path
                if [[ "$target" == "\\"* ]]; then
                    new_path="Exemple\Test\${target:1}\\"
                else
                    new_path="$target\\"
                fi
            else
                # Relative path
                new_path="$current_path$target\\"
            fi
            
            new_path=$(echo "$new_path" | sed 's|\\\\\\\\|\\\\|g')
            
            local in_current_dir=""
            local is_file=0
            local search_dir="${current_path%\\}"
            while IFS= read -r line; do
                if [[ "$line" == directory* ]]; then
                    local dir_path=$(echo "$line" | cut -d' ' -f2-)
                    local dir_path_clean="${dir_path%\\}"
                    if [ "$dir_path_clean" = "$search_dir" ]; then
                        in_current_dir="true"
                    else
                        in_current_dir=""
                    fi
                elif [ "$in_current_dir" = "true" ]; then
                    if [ "$line" = "@" ]; then
                        break
                    elif [[ "$line" == "$target "* ]]; then
                        local parts=($line)
                        local perms="${parts[1]}"
                        if [[ "$perms" != d* ]]; then
                            is_file=1
                        fi
                        break
                    fi
                fi
            done < /tmp/vsh_header
            
            if [ $is_file -eq 1 ]; then
                echo "cd: $target: Not a directory"
                return
            fi
            
            # Check if directory exists
            local check_path="$new_path"
            local grep_pattern="${check_path//\\/\\\\}"
            if grep -q "^directory $grep_pattern\$" /tmp/vsh_header 2>/dev/null; then
                current_path="$new_path"
            else
                echo "cd: $target: No such file or directory"
            fi
            ;;
    esac
}

cmd_cat() {
    # Supporte de fichier multiples
    if [ $# -eq 0 ]; then
        echo "cat: missing file operand"
        return
    fi
    
    for filepath in "$@"; do
        local found=0
        local filename
        local search_path="$current_path"
        
        if [[ "$filepath" == *"\\"* ]]; then
            filename=$(basename "$filepath")
            if [[ "$filepath" == "\\"* ]] || [[ "$filepath" == "Exemple\\\\"* ]]; then
                # Absolute path
                if [[ "$filepath" == "\\"* ]]; then
                    search_path="Exemple\Test\${filepath%\\*}\\"
                else
                    search_path="${filepath%\\*}\\"
                fi
            else
                # Relative path
                search_path="$current_path${filepath%\\*}\\"
            fi
        else
            filename="$filepath"
        fi
        
        local in_current_dir=""
        local search_dir="${search_path%\\}"
        
        while IFS= read -r line; do
            if [[ "$line" == directory* ]]; then
                local dir_path=$(echo "$line" | cut -d' ' -f2-)
                local dir_path_clean="${dir_path%\\}"
                if [ "$dir_path_clean" = "$search_dir" ]; then
                    in_current_dir="true"
                else
                    in_current_dir=""
                fi
            elif [ "$in_current_dir" = "true" ]; then
                if [ "$line" = "@" ]; then
                    break
                elif [[ "$line" == "$filename "* ]]; then
                    local parts=($line)
                    if [ ${#parts[@]} -gt 3 ]; then
                        local start_line="${parts[3]}"
                        local line_count="${parts[4]}"
                        sed -n "${start_line},$((start_line + line_count - 1))p" /tmp/vsh_body
                    else
                        echo "(empty file)"
                    fi
                    found=1
                    break
                fi
            fi
        done < /tmp/vsh_header
        
        if [ $found -eq 0 ]; then
            echo "cat: $filepath: No such file or directory"
        fi
    done
}

cmd_rm() {
    local filepath="$1"
    
    if [ -z "$filepath" ]; then
        echo "rm: missing operand"
        return
    fi
    
    local target
    local search_path="$current_path"
    
    if [[ "$filepath" == *"\\"* ]]; then
        target=$(basename "$filepath")
        if [[ "$filepath" == "\\"* ]] || [[ "$filepath" == "Exemple\\\\"* ]]; then
            if [[ "$filepath" == "\\"* ]]; then
                search_path="Exemple\Test\${filepath%\\*}\\"
            else
                search_path="${filepath%\\*}\\"
            fi
        else
            search_path="$current_path${filepath%\\*}\\"
        fi
    else
        target="$filepath"
    fi
    
    local found=0
    local is_dir=0
    local in_current_dir=""
    local search_dir="${search_path%\\}"
    
    local saved_path="$current_path"
    current_path="$search_path"
    
    while IFS= read -r line; do
        if [[ "$line" == directory* ]]; then
            local dir_path=$(echo "$line" | cut -d' ' -f2-)
            local dir_path_clean="${dir_path%\\}"
            if [ "$dir_path_clean" = "$search_dir" ]; then
                in_current_dir="true"
            else
                in_current_dir=""
            fi
        elif [ "$in_current_dir" = "true" ]; then
            if [ "$line" = "@" ]; then
                break
            elif [[ "$line" == "$target "* ]]; then
                local parts=($line)
                local perms="${parts[1]}"
                if [[ "$perms" == d* ]]; then
                    is_dir=1
                fi
                found=1
                break
            fi
        fi
    done < /tmp/vsh_header
    
    if [ $found -eq 0 ]; then
        echo "rm: cannot remove '$filepath': No such file or directory"
        current_path="$saved_path"
        return
    fi
    
    if [ $is_dir -eq 1 ]; then
        remove_from_archive "$target" 1
    else
        remove_from_archive "$target" 0
    fi
    
    current_path="$saved_path"
    archive_modified=1
}

cmd_touch() {
    local filename="$1"
    
    if [ -z "$filename" ]; then
        echo "touch: missing file operand"
        return
    fi
    
    local found=0
    local in_current_dir=""
    local search_dir="${current_path%\\}"
    
    while IFS= read -r line; do
        if [[ "$line" == directory* ]]; then
            local dir_path=$(echo "$line" | cut -d' ' -f2-)
            local dir_path_clean="${dir_path%\\}"
            if [ "$dir_path_clean" = "$search_dir" ]; then
                in_current_dir="true"
            else
                in_current_dir=""
            fi
        elif [ "$in_current_dir" = "true" ]; then
            if [ "$line" = "@" ]; then
                break
            elif [[ "$line" == "$filename "* ]]; then
                found=1
                break
            fi
        fi
    done < /tmp/vsh_header
    
    if [ $found -eq 1 ]; then
        return
    fi
    
    add_file_to_archive "$filename" "-rw-r--r--" 0 ""
    archive_modified=1
}

cmd_mkdir() {
    local recursive=0
    local dirname=""
    
    if [ "$1" = "-p" ]; then
        recursive=1
        dirname="$2"
    else
        dirname="$1"
    fi
    
    if [ -z "$dirname" ]; then
        echo "mkdir: missing operand"
        return
    fi
    
    if [ $recursive -eq 1 ]; then
        
        local path="$current_path"
        IFS='\\' read -ra DIRS <<< "$dirname"
        for dir in "${DIRS[@]}"; do
            if [ -n "$dir" ]; then
                # Check if directory already exists
                local exists=0
                local check_dir="${path}${dir}"
                local check_grep="${check_dir//\\/\\\\}"
                if grep -q "^directory $check_grep\$" /tmp/vsh_header 2>/dev/null; then
                    exists=1
                fi
                
                if [ $exists -eq 0 ]; then
                    # Create directory
                    add_directory_to_archive "${path}${dir}" "drwxr-xr-x" 4096
                    archive_modified=1
                fi
                path="${path}${dir}\\\\"
            fi
        done
    else
       
        local target_path="${current_path}${dirname}\\\\"
        local target_path_clean="${target_path%\\}"
        local target_grep="${target_path_clean//\\/\\\\}"
        if grep -q "^directory $target_grep\$" /tmp/vsh_header 2>/dev/null; then
            echo "mkdir: cannot create directory '$dirname': File exists"
            return
        fi
        
        local parent_clean="${current_path%\\}"
        local parent_grep="${parent_clean//\\/\\\\}"
        if ! grep -q "^directory $parent_grep\$" /tmp/vsh_header 2>/dev/null && \
           ! grep -q "^directory $parent_grep\\\\\$" /tmp/vsh_header 2>/dev/null; then
            echo "mkdir: cannot create directory '$dirname': No such file or directory"
            return
        fi
        
        add_directory_to_archive "${current_path}${dirname}" "drwxr-xr-x" 4096
        archive_modified=1
    fi
}

main() {
    if [ $# -lt 3 ]; then
        show_usage
        exit 1
    fi
    
    local mode=$1
    local server=$2
    local port=$3
    local archive_name=$4
    local directory=$5  
    
    case "$mode" in
        "-list")
            list_mode "$server" "$port"
            ;;
        "-browse")
            if [ -z "$archive_name" ]; then
                echo "Error: archive_name required for browse mode"
                show_usage
                exit 1
            fi
            
            echo "Entering browse mode for archive '$archive_name'"
            
            local response=$(send_command "$server" "$port" "GET $archive_name")
            
            if [[ "$response" == "ERROR:"* ]]; then
                echo "Error: Could not retrieve archive '$archive_name'"
                exit 1
            fi
            
            local temp_archive=$(mktemp)
            echo "$response" > "$temp_archive"
            
            local first_line=$(head -n 1 "$temp_archive")
            local body_start=$(echo "$first_line" | cut -d: -f2)
            local header_end=$((body_start - 1))
            sed -n "2,${header_end}p" "$temp_archive" > /tmp/vsh_header
            sed -n "${body_start},\$p" "$temp_archive" > /tmp/vsh_body
            
            current_path="Exemple\Test\\"
            archive_modified=0
            echo "Archive loaded. Type 'exit' to quit."
            
            while true; do
                echo -n "vsh:> "
                if ! read -r command args; then
                    if [ $archive_modified -eq 1 ]; then
                        echo
                        echo "Saving changes to archive..."
                        save_archive_to_server "$archive_name"
                    fi
                    break
                fi
                
                case "$command" in
                    "exit"|"quit")
                        if [ $archive_modified -eq 1 ]; then
                            echo "Saving changes to archive..."
                            save_archive_to_server "$archive_name"
                        fi
                        break
                        ;;
                    "pwd")
                        # Display path relative to archive root
                        local display_path="${current_path#Exemple\\Test\\}"
                        if [ -z "$display_path" ]; then
                            echo "\\"
                        else
                            echo "\\$display_path"
                        fi
                        ;;
                    "ls")
                        cmd_ls $args
                        ;;
                    "cd")
                        cmd_cd $args
                        ;;
                    "cat")
                        cmd_cat $args
                        ;;
                    "rm")
                        cmd_rm $args
                        ;;
                    "touch")
                        cmd_touch $args
                        ;;
                    "mkdir")
                        cmd_mkdir $args
                        ;;
                    "")
                        continue
                        ;;
                    *)
                        echo "Unknown command: $command"
                        ;;
                esac
            done
            
            rm -f "$temp_archive" /tmp/vsh_header /tmp/vsh_body
            ;;
        "-extract")
            if [ -z "$archive_name" ]; then
                echo "Error: archive_name required for extract mode"
                show_usage
                exit 1
            fi
            extract_mode "$server" "$port" "$archive_name" "$directory"
            ;;
        "-create")
            if [ -z "$archive_name" ]; then
                echo "Error: archive_name required for create mode"
                show_usage
                exit 1
            fi
            create_mode "$server" "$port" "$archive_name" "$directory"
            ;;
        *)
            echo "Error: Invalid mode '$mode'"
            show_usage
            exit 1
            ;;
    esac
}


main "$@"
