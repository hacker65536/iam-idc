#!/bin/bash

# iam-idc.sh - AWS IAM Identity Center CLI Tool
# AWS Management Console の表示、操作を command line interface で実現する

set -e

# 色付きの出力用の定数
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ヘルプメッセージを表示
show_help() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "AWS IAM Identity Center CLI Tool"
    echo ""
    echo "Commands:"
    echo "  list-groups [SEARCH_TERM]      グループ一覧を表示（オプション：グループ名での検索）"
    echo "  list-users                     全ユーザー一覧を表示"
    echo "  list-users-in-group [GROUP_ID] 指定されたグループのユーザ一覧を表示（引数なしでfzf選択）"
    echo "  help                           このヘルプメッセージを表示"
    echo ""
    echo "Options:"
    echo "  --profile PROFILE              AWS プロファイルを指定"
    echo "  --region REGION                AWS リージョンを指定"
    echo "  --identity-store-id ID         Identity Store ID を指定"
    echo "  --output FORMAT                出力形式を指定 (table|json|text) [default: text]"
    echo "  --format                       column -t を使用して出力を整形 [default: enabled]"
    echo "  --debug                        デバッグ情報を表示"
    echo ""
    echo "Examples:"
    echo "  $0 list-groups"
    echo "  $0 list-groups Admin"
    echo "  $0 list-users"
    echo "  $0 list-users-in-group"
    echo "  $0 list-users-in-group group-12345678"
    echo "  $0 list-groups --profile myprofile"
    echo "  $0 list-users --identity-store-id d-1234567890"
    echo "  $0 list-groups --output json"
    echo "  $0 list-users --output text"
    echo "  $0 list-groups --output text --format"
    echo "  $0 list-users --output text --format"
    echo "  $0 list-groups --debug"
    echo "  $0 list-users --debug"
    echo "  $0 list-groups Proj --debug"
}

# エラーメッセージを表示
error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

# 成功メッセージを表示（デバッグモード時のみ）
success() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${GREEN}$1${NC}"
    fi
}

# 警告メッセージを表示（デバッグモード時のみ）
warning() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${YELLOW}Warning: $1${NC}"
    fi
}

# 情報メッセージを表示（デバッグモード時のみ）
info() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${BLUE}$1${NC}"
    fi
}

# AWS CLI がインストールされているかチェック
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        error "AWS CLI がインストールされていません。インストールしてください。"
    fi
}

# column コマンドがインストールされているかチェック
check_column_command() {
    if [ "$USE_COLUMN_FORMAT" = true ] && ! command -v column &> /dev/null; then
        error "column コマンドがインストールされていません。--format オプションを使用するには column コマンドが必要です。"
    fi
}

# fzf コマンドがインストールされているかチェック
check_fzf_command() {
    if ! command -v fzf &> /dev/null; then
        error "fzf コマンドがインストールされていません。インタラクティブなグループ選択にはfzfが必要です。"
    fi
}

# スピナーを表示する関数
show_spinner() {
    local pid=$1
    local message="$2"
    local spinner_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0
    
    # カーソルを非表示にする
    tput civis 2>/dev/null || true
    
    while kill -0 "$pid" 2>/dev/null; do
        local char=${spinner_chars:$i:1}
        printf "\r%s %s" "$char" "$message"
        i=$(( (i + 1) % ${#spinner_chars} ))
        sleep 0.1
    done
    
    # スピナーをクリア
    printf "\r%*s\r" ${#message} ""
    
    # カーソルを表示に戻す
    tput cnorm 2>/dev/null || true
}

# バックグラウンドでコマンドを実行してスピナーを表示
execute_with_spinner() {
    local message="$1"
    shift
    local cmd="$*"
    
    # バックグラウンドでコマンドを実行
    eval "$cmd" &
    local cmd_pid=$!
    
    # スピナーを表示
    show_spinner "$cmd_pid" "$message"
    
    # コマンドの完了を待つ
    wait "$cmd_pid"
    return $?
}

# 出力を整形する関数
format_output() {
    local output="$1"
    
    if [ "$USE_COLUMN_FORMAT" = true ] && [ "$OUTPUT_FORMAT" = "text" ]; then
        echo "$output" | column -t -s $'\t'
    else
        echo "$output"
    fi
}

# AWS CLIコマンドを構築する共通関数
build_aws_command() {
    local base_cmd="$1"
    local cmd="$base_cmd"
    
    if [ -n "$AWS_PROFILE_OPTION" ]; then
        cmd="$cmd $AWS_PROFILE_OPTION"
    fi
    if [ -n "$AWS_REGION_OPTION" ]; then
        cmd="$cmd $AWS_REGION_OPTION"
    fi
    
    echo "$cmd"
}

# 単一ユーザ情報を取得する関数（並列処理用）
get_user_info() {
    local identity_store_id="$1"
    local user_id="$2"
    local query="$3"
    local output_format="$4"
    local aws_profile_option="$5"
    local aws_region_option="$6"
    
    local aws_cmd
    aws_cmd=$(build_aws_command "aws identitystore describe-user --identity-store-id '$identity_store_id' --user-id '$user_id'")
    aws_cmd="$aws_cmd --query '$query' --output '$output_format'"
    
    local user_info
    if user_info=$(eval "$aws_cmd" 2>/dev/null) && [ -n "$user_info" ]; then
        echo "$user_info"
    else
        warning "ユーザ '$user_id' の詳細情報を取得できませんでした。"
        return 1
    fi
}

# Identity Store ID を取得
get_identity_store_id() {
    if [ -n "$IDENTITY_STORE_ID" ]; then
        echo "$IDENTITY_STORE_ID"
        return
    fi
    
    info "Identity Store ID を取得中..." >&2
    local identity_store_id
    local aws_cmd
    aws_cmd=$(build_aws_command "aws sso-admin list-instances")
    aws_cmd="$aws_cmd --query 'Instances[0].IdentityStoreId' --output text"
    
    if ! identity_store_id=$(eval "$aws_cmd" 2>/dev/null); then
        error "Identity Store ID の取得に失敗しました。AWS CLI の設定を確認してください。"
    fi
    
    if [ "$identity_store_id" = "None" ] || [ -z "$identity_store_id" ]; then
        error "Identity Store ID を取得できませんでした。--identity-store-id オプションで指定してください。"
    fi
    
    echo "$identity_store_id"
}

# グループ一覧を表示
list_groups() {
    local search_info=""
    if [ -n "$SEARCH_TERM" ]; then
        search_info=" (検索語: '$SEARCH_TERM')"
        info "グループ一覧を取得中$search_info..."
    else
        info "グループ一覧を取得中..."
    fi
    
    local identity_store_id
    identity_store_id=$(get_identity_store_id)
    
    local groups
    local query
    
    # 出力形式に応じてクエリを変更
    case $OUTPUT_FORMAT in
        json)
            query='Groups[*].{GroupId:GroupId,DisplayName:DisplayName}'
            ;;
        text)
            query='Groups[*].[GroupId,DisplayName]'
            ;;
        table)
            query='Groups[*].[GroupId,DisplayName]'
            ;;
    esac
    
    local aws_cmd
    aws_cmd=$(build_aws_command "aws identitystore list-groups --identity-store-id '$identity_store_id'")
    aws_cmd="$aws_cmd --query '$query' --output '$OUTPUT_FORMAT'"
    
    if groups=$(eval "$aws_cmd" 2>/dev/null) && [ -n "$groups" ]; then
        # 検索語が指定されている場合はフィルタリング
        if [ -n "$SEARCH_TERM" ]; then
            local filtered_groups
            if [ "$OUTPUT_FORMAT" = "json" ]; then
                # JSON形式の場合は jq を使用してフィルタリング
                if command -v jq &> /dev/null; then
                    filtered_groups=$(echo "$groups" | jq --arg search "$SEARCH_TERM" '[.[] | select(.DisplayName | type == "string" and test($search; "i"))]')
                else
                    # jq がない場合は grep でフィルタリング
                    filtered_groups=$(echo "$groups" | grep -i "$SEARCH_TERM" || true)
                fi
            else
                # text/table形式の場合は grep でフィルタリング
                filtered_groups=$(echo "$groups" | grep -i "$SEARCH_TERM" || true)
            fi
            
            if [ -n "$filtered_groups" ] && [ "$filtered_groups" != "[]" ]; then
                groups="$filtered_groups"
            else
                warning "検索語 '$SEARCH_TERM' に一致するグループが見つかりませんでした。"
                return
            fi
        fi
        
        # 各グループのユーザ数を並列で取得（スピナー付き）
        local temp_dir
        temp_dir=$(mktemp -d)
        local groups_with_count=""
        
        # スピナー表示のためのバックグラウンド処理
        {
            local pids=()
            local group_count=0
            local max_parallel=30  # 並列実行数を増加
            
            if [ "$OUTPUT_FORMAT" = "json" ]; then
                # JSON形式の場合 - バッチ並列処理
                if command -v jq &> /dev/null; then
                    # グループIDを配列に格納
                    local group_ids=()
                    while IFS= read -r group_json; do
                        local group_id
                        group_id=$(echo "$group_json" | jq -r '.GroupId')
                        group_ids+=("$group_id")
                        echo "$group_json" > "$temp_dir/group_orig_$group_count.json"
                        ((group_count++))
                    done < <(echo "$groups" | jq -c '.[]')
                    
                    # バッチ並列処理でユーザ数を取得
                    for ((i=0; i<${#group_ids[@]}; i++)); do
                        {
                            local user_count
                            user_count=$(get_group_user_count "$identity_store_id" "${group_ids[$i]}")
                            jq --arg count "$user_count" '. + {UserCount: ($count | tonumber)}' "$temp_dir/group_orig_$i.json" > "$temp_dir/group_$i.json"
                        } &
                        pids+=($!)
                        
                        # 並列実行数制限
                        if (( ${#pids[@]} >= max_parallel )); then
                            for pid in "${pids[@]}"; do
                                wait "$pid" 2>/dev/null || true
                            done
                            pids=()
                        fi
                    done
                    
                    # 残りのプロセスを待つ
                    for pid in "${pids[@]}"; do
                        wait "$pid" 2>/dev/null || true
                    done
                    
                    # 結果を効率的に結合
                    groups_with_count=$(find "$temp_dir" -name "group_*.json" -not -name "group_orig_*.json" | sort -V | xargs cat | jq -s .)
                else
                    groups_with_count="$groups"
                fi
            else
                # text/table形式の場合 - バッチ並列処理
                local group_lines=()
                while IFS= read -r line; do
                    group_lines+=("$line")
                    ((group_count++))
                done <<< "$groups"
                
                # バッチ並列処理でユーザ数を取得
                pids=()
                for ((i=0; i<${#group_lines[@]}; i++)); do
                    {
                        local group_id
                        group_id=$(echo "${group_lines[$i]}" | awk '{print $1}')
                        local user_count
                        user_count=$(get_group_user_count "$identity_store_id" "$group_id")
                        printf "%s\t%s\n" "${group_lines[$i]}" "$user_count" > "$temp_dir/group_$i.txt"
                    } &
                    pids+=($!)
                    
                    # 並列実行数制限
                    if (( ${#pids[@]} >= max_parallel )); then
                        for pid in "${pids[@]}"; do
                            wait "$pid" 2>/dev/null || true
                        done
                        pids=()
                    fi
                done
                
                # 残りのプロセスを待つ
                for pid in "${pids[@]}"; do
                    wait "$pid" 2>/dev/null || true
                done
                
                # 結果を効率的に結合
                groups_with_count=$(find "$temp_dir" -name "group_*.txt" | sort -V | xargs cat)
            fi
            
            # 結果を一時ファイルに保存
            echo "$groups_with_count" > "$temp_dir/final_result.txt"
        } &
        
        local process_pid=$!
        
        # デバッグモードでない場合はスピナーを表示
        if [ "$DEBUG_MODE" != true ]; then
            show_spinner "$process_pid" "各グループのユーザ数を取得中..."
        else
            info "各グループのユーザ数を取得中..."
        fi
        
        # プロセスの完了を待つ
        wait "$process_pid"
        
        # 結果を読み込み
        if [ -f "$temp_dir/final_result.txt" ]; then
            groups_with_count=$(cat "$temp_dir/final_result.txt")
        fi
        
        # 一時ディレクトリを削除
        rm -rf "$temp_dir"
        
        # グループ数を計算
        local total_groups=0
        if [ "$OUTPUT_FORMAT" = "json" ]; then
            if command -v jq &> /dev/null; then
                total_groups=$(echo "$groups_with_count" | jq 'length')
            fi
        else
            total_groups=$(echo "$groups_with_count" | wc -l)
        fi
        
        echo ""
        local format_suffix=""
        if [ "$USE_COLUMN_FORMAT" = true ] && [ "$OUTPUT_FORMAT" = "text" ]; then
            format_suffix=" (column整形)"
        fi
        success "グループ一覧$search_info ($OUTPUT_FORMAT 形式$format_suffix):"
        format_output "$groups_with_count"
        
        # 合計グループ数を表示
        echo ""
        echo "合計グループ数: $total_groups"
    else
        error "グループ一覧の取得に失敗しました。"
    fi
}

# グループのユーザ数を取得する関数（ページネーション対応）
get_group_user_count() {
    local identity_store_id="$1"
    local group_id="$2"
    
    local total_count=0
    local next_token=""
    
    while true; do
        local aws_cmd
        aws_cmd=$(build_aws_command "aws identitystore list-group-memberships --identity-store-id '$identity_store_id' --group-id '$group_id'")
        
        # ページネーション用のトークンがある場合は追加
        if [ -n "$next_token" ]; then
            aws_cmd="$aws_cmd --starting-token '$next_token'"
        fi
        
        aws_cmd="$aws_cmd --output json"
        
        local result
        if result=$(eval "$aws_cmd" 2>/dev/null) && [ -n "$result" ]; then
            # 現在のページのメンバー数を取得
            local page_count
            if command -v jq &> /dev/null; then
                page_count=$(echo "$result" | jq '.GroupMemberships | length')
                next_token=$(echo "$result" | jq -r '.NextToken // empty')
            else
                # jqがない場合は従来の方法（100件制限あり）
                page_count=$(echo "$result" | grep -o '"UserId"' | wc -l)
                next_token=""
            fi
            
            if [[ "$page_count" =~ ^[0-9]+$ ]]; then
                ((total_count += page_count))
            fi
            
            # NextTokenがない場合は終了
            if [ -z "$next_token" ] || [ "$next_token" = "null" ]; then
                break
            fi
        else
            break
        fi
    done
    
    echo "$total_count"
}

# グループ名からグループIDを取得する関数
get_group_id_by_name() {
    local identity_store_id="$1"
    local group_name="$2"
    
    local aws_cmd
    aws_cmd=$(build_aws_command "aws identitystore list-groups --identity-store-id '$identity_store_id'")
    aws_cmd="$aws_cmd --output json"
    
    local groups
    if groups=$(eval "$aws_cmd" 2>/dev/null) && [ -n "$groups" ]; then
        local group_id
        if command -v jq &> /dev/null; then
            # 完全一致を優先し、見つからない場合は部分一致
            group_id=$(echo "$groups" | jq -r --arg name "$group_name" '.Groups[] | select(.DisplayName == $name) | .GroupId' | head -n 1)
            if [ -z "$group_id" ] || [ "$group_id" = "null" ]; then
                group_id=$(echo "$groups" | jq -r --arg name "$group_name" '.Groups[] | select(.DisplayName | test($name; "i")) | .GroupId' | head -n 1)
            fi
        else
            # jqがない場合はgrepで検索
            group_id=$(echo "$groups" | grep -i "\"DisplayName\": \".*$group_name.*\"" -A 10 -B 10 | grep "\"GroupId\"" | head -n 1 | sed 's/.*"GroupId": "\([^"]*\)".*/\1/')
        fi
        
        if [ -n "$group_id" ] && [ "$group_id" != "null" ]; then
            echo "$group_id"
        else
            return 1
        fi
    else
        return 1
    fi
}

# 引数がグループIDかグループ名かを判定し、グループIDを返す関数
resolve_group_identifier() {
    local identity_store_id="$1"
    local identifier="$2"
    
    # UUIDの形式（xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）かチェック
    if [[ "$identifier" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        # グループIDの形式の場合はそのまま返す
        echo "$identifier"
    else
        # グループ名として検索
        local group_id
        group_id=$(get_group_id_by_name "$identity_store_id" "$identifier")
        if [ $? -eq 0 ] && [ -n "$group_id" ]; then
            info "グループ名 '$identifier' をグループID '$group_id' に解決しました。" >&2
            echo "$group_id"
        else
            error "グループ名 '$identifier' に一致するグループが見つかりませんでした。"
        fi
    fi
}

# fzfを使ってグループを選択する関数
select_group_with_fzf() {
    info "グループ一覧を取得中..." >&2
    
    local identity_store_id
    identity_store_id=$(get_identity_store_id)
    
    # グループ一覧を取得（fzf用のフォーマット）
    local groups_for_fzf
    local aws_cmd
    aws_cmd=$(build_aws_command "aws identitystore list-groups --identity-store-id '$identity_store_id'")
    aws_cmd="$aws_cmd --query 'Groups[*].[GroupId,DisplayName]' --output text"
    
    if ! groups_for_fzf=$(eval "$aws_cmd" 2>/dev/null) || [ -z "$groups_for_fzf" ]; then
        error "グループ一覧の取得に失敗しました。"
    fi
    
    # fzfでグループを選択
    info "fzfでグループを選択してください..." >&2
    local selected_line
    selected_line=$(echo "$groups_for_fzf" | fzf \
        --height=50% \
        --layout=reverse \
        --border \
        --prompt="グループを選択: " \
        --preview-window=right:50%:wrap \
        --preview='echo "Group ID: {1}"; echo "Name: {2}"' \
        --header="↑↓で選択、Enterで決定、Escでキャンセル")
    
    if [ -z "$selected_line" ]; then
        warning "グループが選択されませんでした。" >&2
        exit 0
    fi
    
    # 選択されたグループIDを抽出
    local selected_group_id
    selected_group_id=$(echo "$selected_line" | awk '{print $1}')
    
    if [ -z "$selected_group_id" ]; then
        error "グループIDの抽出に失敗しました。"
    fi
    
    echo "$selected_group_id"
}

# 全ユーザー一覧を表示
list_users() {
    info "全ユーザー一覧を取得中..."
    
    local identity_store_id
    identity_store_id=$(get_identity_store_id)
    
    local users
    local query
    
    # 出力形式に応じてクエリを変更
    case $OUTPUT_FORMAT in
        json)
            query='Users[*].{UserId:UserId,UserName:UserName,DisplayName:DisplayName,Email:Emails[0].Value}'
            ;;
        text)
            query='Users[*].[UserId,UserName,DisplayName,Emails[0].Value]'
            ;;
        table)
            query='Users[*].[UserId,UserName,DisplayName,Emails[0].Value]'
            ;;
    esac
    
    local aws_cmd
    aws_cmd=$(build_aws_command "aws identitystore list-users --identity-store-id '$identity_store_id'")
    aws_cmd="$aws_cmd --query '$query' --output '$OUTPUT_FORMAT'"
    
    # スピナー表示のためのバックグラウンド処理
    {
        if users=$(eval "$aws_cmd" 2>/dev/null) && [ -n "$users" ]; then
            echo "$users" > "/tmp/users_result.txt"
        else
            echo "ERROR" > "/tmp/users_result.txt"
        fi
    } &
    
    local process_pid=$!
    
    # デバッグモードでない場合はスピナーを表示
    if [ "$DEBUG_MODE" != true ]; then
        show_spinner "$process_pid" "全ユーザー一覧を取得中..."
    fi
    
    # プロセスの完了を待つ
    wait "$process_pid"
    
    # 結果を読み込み
    if [ -f "/tmp/users_result.txt" ]; then
        local result
        result=$(cat "/tmp/users_result.txt")
        rm -f "/tmp/users_result.txt"
        
        if [ "$result" = "ERROR" ]; then
            error "ユーザー一覧の取得に失敗しました。"
        fi
        
        # ユーザー数を計算
        local total_users=0
        if [ "$OUTPUT_FORMAT" = "json" ]; then
            if command -v jq &> /dev/null; then
                total_users=$(echo "$result" | jq 'length')
            fi
        else
            total_users=$(echo "$result" | wc -l)
        fi
        
        echo ""
        local format_suffix=""
        if [ "$USE_COLUMN_FORMAT" = true ] && [ "$OUTPUT_FORMAT" = "text" ]; then
            format_suffix=" (column整形)"
        fi
        success "全ユーザー一覧 ($OUTPUT_FORMAT 形式$format_suffix):"
        format_output "$result"
        
        # 合計ユーザー数を表示
        echo ""
        echo "合計ユーザー数: $total_users"
    else
        error "ユーザー一覧の取得に失敗しました。"
    fi
}

# 指定されたグループのユーザ一覧を表示
list_users_in_group() {
    local group_id="$1"
    
    if [ -z "$group_id" ]; then
        error "グループIDが指定されていません。"
    fi
    
    info "グループ '$group_id' のユーザ一覧を取得中..."
    
    local identity_store_id
    identity_store_id=$(get_identity_store_id)
    
    # グループのメンバーシップを取得
    local memberships
    local aws_cmd
    aws_cmd=$(build_aws_command "aws identitystore list-group-memberships --identity-store-id '$identity_store_id' --group-id '$group_id'")
    aws_cmd="$aws_cmd --query 'GroupMemberships[*].MemberId.UserId' --output text"
    
    if ! memberships=$(eval "$aws_cmd" 2>/dev/null); then
        error "グループメンバーシップの取得に失敗しました。グループID '$group_id' が正しいか確認してください。"
    fi
    
    if [ -z "$memberships" ] || [ "$memberships" = "None" ]; then
        warning "グループ '$group_id' にはユーザが所属していません。"
        return
    fi
    
    echo ""
    local format_suffix=""
    if [ "$USE_COLUMN_FORMAT" = true ] && [ "$OUTPUT_FORMAT" = "text" ]; then
        format_suffix=" (column整形)"
    fi
    success "グループ '$group_id' のユーザ一覧 ($OUTPUT_FORMAT 形式$format_suffix):"
    echo ""
    
    # 出力形式に応じてクエリを変更
    local query
    case $OUTPUT_FORMAT in
        json)
            query='{UserId:UserId,UserName:UserName,DisplayName:DisplayName,Email:Emails[0].Value}'
            ;;
        text)
            query='[UserId,UserName,DisplayName,Emails[0].Value]'
            ;;
        table)
            query='[UserId,UserName,DisplayName,Emails[0].Value]'
            ;;
    esac
    
    # text形式でcolumn整形を使用する場合は、全ユーザ情報を並列で取得して整形
    if [ "$USE_COLUMN_FORMAT" = true ] && [ "$OUTPUT_FORMAT" = "text" ]; then
        local temp_dir
        temp_dir=$(mktemp -d)
        
        # スピナー表示のためのバックグラウンド処理
        {
            local pids=()
            local user_count=0
            
            # 各ユーザ情報を並列で取得
            for user_id in $memberships; do
                {
                    local user_info
                    if user_info=$(get_user_info "$identity_store_id" "$user_id" "$query" "$OUTPUT_FORMAT" "$AWS_PROFILE_OPTION" "$AWS_REGION_OPTION") && [ -n "$user_info" ]; then
                        echo "$user_info" > "$temp_dir/user_$user_count.txt"
                    fi
                } &
                pids+=($!)
                ((user_count++))
            done
            
            # すべてのバックグラウンドプロセスの完了を待つ
            for pid in "${pids[@]}"; do
                wait "$pid"
            done
            
            # 結果を結合
            local all_users=""
            for ((i=0; i<user_count; i++)); do
                if [ -f "$temp_dir/user_$i.txt" ]; then
                    local user_info
                    user_info=$(cat "$temp_dir/user_$i.txt")
                    if [ -n "$user_info" ]; then
                        if [ -z "$all_users" ]; then
                            all_users="$user_info"
                        else
                            all_users="${all_users}"$'\n'"${user_info}"
                        fi
                    fi
                fi
            done
            
            # 結果を一時ファイルに保存
            echo "$all_users" > "$temp_dir/final_users.txt"
        } &
        
        local process_pid=$!
        
        # デバッグモードでない場合はスピナーを表示
        if [ "$DEBUG_MODE" != true ]; then
            show_spinner "$process_pid" "ユーザ情報を取得中..."
        fi
        
        # プロセスの完了を待つ
        wait "$process_pid"
        
        # 結果を読み込み
        if [ -f "$temp_dir/final_users.txt" ]; then
            local all_users
            all_users=$(cat "$temp_dir/final_users.txt")
            if [ -n "$all_users" ]; then
                format_output "$all_users"
            fi
        fi
        
        # 一時ディレクトリを削除
        rm -rf "$temp_dir"
    else
        # 通常の処理（各ユーザごとに並列で取得して表示）
        local temp_dir
        temp_dir=$(mktemp -d)
        
        # スピナー表示のためのバックグラウンド処理
        {
            local pids=()
            local user_count=0
            
            # 各ユーザ情報を並列で取得
            for user_id in $memberships; do
                {
                    local user_info
                    if user_info=$(get_user_info "$identity_store_id" "$user_id" "$query" "$OUTPUT_FORMAT" "$AWS_PROFILE_OPTION" "$AWS_REGION_OPTION") && [ -n "$user_info" ]; then
                        echo "$user_info" > "$temp_dir/user_$user_count.txt"
                    fi
                } &
                pids+=($!)
                ((user_count++))
            done
            
            # すべてのバックグラウンドプロセスの完了を待つ
            for pid in "${pids[@]}"; do
                wait "$pid"
            done
            
            # 結果を順番に結合
            for ((i=0; i<user_count; i++)); do
                if [ -f "$temp_dir/user_$i.txt" ]; then
                    local user_info
                    user_info=$(cat "$temp_dir/user_$i.txt")
                    if [ -n "$user_info" ]; then
                        echo "$user_info" >> "$temp_dir/final_output.txt"
                        if [ "$OUTPUT_FORMAT" = "table" ]; then
                            echo "" >> "$temp_dir/final_output.txt"
                        fi
                    fi
                fi
            done
        } &
        
        local process_pid=$!
        
        # デバッグモードでない場合はスピナーを表示
        if [ "$DEBUG_MODE" != true ]; then
            show_spinner "$process_pid" "ユーザ情報を取得中..."
        fi
        
        # プロセスの完了を待つ
        wait "$process_pid"
        
        # 結果を出力
        if [ -f "$temp_dir/final_output.txt" ]; then
            cat "$temp_dir/final_output.txt"
        fi
        
        # 一時ディレクトリを削除
        rm -rf "$temp_dir"
    fi
}

# メイン処理
main() {
    # AWS CLI のチェック
    check_aws_cli
    
    # オプションの初期化
    AWS_PROFILE_OPTION=""
    AWS_REGION_OPTION=""
    IDENTITY_STORE_ID=""
    OUTPUT_FORMAT="text"
    USE_COLUMN_FORMAT=true
    DEBUG_MODE=false
    COMMAND=""
    GROUP_ID=""
    SEARCH_TERM=""
    
    # 引数の解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                AWS_PROFILE_OPTION="--profile $2"
                shift 2
                ;;
            --region)
                AWS_REGION_OPTION="--region $2"
                shift 2
                ;;
            --identity-store-id)
                IDENTITY_STORE_ID="$2"
                shift 2
                ;;
            --output)
                case $2 in
                    table|json|text)
                        OUTPUT_FORMAT="$2"
                        ;;
                    *)
                        error "無効な出力形式: $2 (table, json, text のいずれかを指定してください)"
                        ;;
                esac
                shift 2
                ;;
            --format)
                USE_COLUMN_FORMAT=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            list-groups)
                COMMAND="list-groups"
                shift
                if [[ $# -gt 0 && ! $1 =~ ^-- ]]; then
                    SEARCH_TERM="$1"
                    shift
                fi
                ;;
            list-users)
                COMMAND="list-users"
                shift
                ;;
            list-users-in-group)
                COMMAND="list-users-in-group"
                if [[ $# -gt 1 && ! $2 =~ ^-- ]]; then
                    GROUP_ID="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            help|--help|-h)
                show_help
                exit 0
                ;;
            *)
                error "不明なオプション: $1\n$(show_help)"
                ;;
        esac
    done
    
    # コマンドが指定されていない場合はヘルプを表示
    if [ -z "$COMMAND" ]; then
        show_help
        exit 0
    fi
    
    # column コマンドのチェック
    check_column_command
    
    # コマンドの実行
    case $COMMAND in
        list-groups)
            list_groups
            ;;
        list-users)
            list_users
            ;;
        list-users-in-group)
            if [ -z "$GROUP_ID" ]; then
                # fzfのチェック
                check_fzf_command
                # fzfでグループを選択
                GROUP_ID=$(select_group_with_fzf)
            else
                # 引数がある場合はグループ名/IDを解決
                local identity_store_id
                identity_store_id=$(get_identity_store_id)
                GROUP_ID=$(resolve_group_identifier "$identity_store_id" "$GROUP_ID")
            fi
            list_users_in_group "$GROUP_ID"
            ;;
        *)
            error "不明なコマンド: $COMMAND"
            ;;
    esac
}

# スクリプトが直接実行された場合のみメイン処理を実行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
