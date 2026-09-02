#!/usr/bin/env bash
set -euo pipefail

row_ids=(RM-01 RM-02 RM-03 RM-04 RM-05 RM-06 RM-07 RM-08 RM-09 RM-10 RM-11 RM-12 RM-13 RM-14 RM-15)

usage() {
    echo "usage: $0 --validate-only FILE | --initialize ROLE OUTPUT | --record FILE ROW PASS|FAIL EVIDENCE_ID none|direct|relay|peer-relay" >&2
    exit 2
}

validate_markdown() {
    local document="$1"
    [[ -f "$document" ]] || return 1
    for row_id in "${row_ids[@]}"; do
        line="$(rg -n "^\| ${row_id} \|" "$document" || true)"
        [[ -n "$line" && "$line" == *"| NOT RUN |"* ]] || return 1
    done
    if rg -n '^\| RM-[0-9]+ \|.*\| (PASS|FAIL) \|' "$document" >/dev/null; then return 1; fi
}

validate_json() {
    local document="$1"
    [[ -f "$document" ]] || return 1
    local role
    role="$(plutil -extract role raw -o - "$document" 2>/dev/null || true)"
    [[ "$role" == A || "$role" == B || "$role" == C ]] || return 1
    local index=0
    for row_id in "${row_ids[@]}"; do
        [[ "$(plutil -extract "rows.${index}.id" raw -o - "$document" 2>/dev/null || true)" == "$row_id" ]] || return 1
        status="$(plutil -extract "rows.${index}.status" raw -o - "$document" 2>/dev/null || true)"
        [[ "$status" == "NOT RUN" || "$status" == PASS || "$status" == FAIL ]] || return 1
        route="$(plutil -extract "rows.${index}.route" raw -o - "$document" 2>/dev/null || true)"
        [[ "$route" == none || "$route" == direct || "$route" == relay || "$route" == peer-relay ]] || return 1
        evidence="$(plutil -extract "rows.${index}.evidenceID" raw -o - "$document" 2>/dev/null || true)"
        if [[ "$status" == "NOT RUN" ]]; then
            [[ -z "$evidence" ]] || return 1
        else
            [[ "$evidence" =~ ^E-[A-Z0-9-]{8,64}$ ]] || return 1
        fi
        index=$((index + 1))
    done
}

[[ $# -ge 2 ]] || usage
case "$1" in
    --validate-only)
        [[ $# -eq 2 ]] || usage
        case "$2" in
            *.md) validate_markdown "$2" ;;
            *.json) validate_json "$2" ;;
            *) usage ;;
        esac
        echo "personal mesh acceptance schema PASS"
        ;;
    --initialize)
        [[ $# -eq 3 ]] || usage
        role="$2"
        output="$3"
        [[ "$role" == A || "$role" == B || "$role" == C ]] || usage
        umask 077
        plutil -create xml1 "$output"
        plutil -insert schemaVersion -integer 1 "$output"
        plutil -insert role -string "$role" "$output"
        plutil -insert rows -array "$output"
        index=0
        for row_id in "${row_ids[@]}"; do
            plutil -insert "rows.${index}" -dictionary "$output"
            plutil -insert "rows.${index}.id" -string "$row_id" "$output"
            plutil -insert "rows.${index}.status" -string "NOT RUN" "$output"
            plutil -insert "rows.${index}.evidenceID" -string "" "$output"
            plutil -insert "rows.${index}.route" -string none "$output"
            index=$((index + 1))
        done
        plutil -convert json "$output"
        chmod 600 "$output"
        validate_json "$output"
        echo "已为 Mac $role 创建全部 NOT RUN 的验收文件"
        ;;
    --record)
        [[ $# -eq 6 ]] || usage
        document="$2"
        requested_id="$3"
        requested_status="$4"
        evidence_id="$5"
        route="$6"
        [[ "$requested_status" == PASS || "$requested_status" == FAIL ]] || usage
        [[ "$evidence_id" =~ ^E-[A-Z0-9-]{8,64}$ ]] || usage
        [[ "$route" == none || "$route" == direct || "$route" == relay || "$route" == peer-relay ]] || usage
        validate_json "$document"
        index=-1
        for candidate_index in "${!row_ids[@]}"; do
            if [[ "${row_ids[$candidate_index]}" == "$requested_id" ]]; then
                index="$candidate_index"
                break
            fi
        done
        [[ "$index" -ge 0 ]] || usage
        plutil -replace "rows.${index}.status" -string "$requested_status" "$document"
        plutil -replace "rows.${index}.evidenceID" -string "$evidence_id" "$document"
        plutil -replace "rows.${index}.route" -string "$route" "$document"
        validate_json "$document"
        echo "已记录 ${requested_id}；文件不包含 IP、主机名或原始网络状态"
        ;;
    *) usage ;;
esac
