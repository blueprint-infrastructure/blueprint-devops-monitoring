#!/bin/bash

# Validation script for monitoring repository
# Validates Prometheus alert rules and Grafana dashboards

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ERRORS=0
WARNINGS=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Validating monitoring repository: ${REPO_ROOT}"
echo "=========================================="
echo ""

# Check for promtool
if ! command -v promtool &> /dev/null; then
    echo -e "${YELLOW}Warning: promtool not found. Skipping Prometheus rule validation.${NC}"
    echo "Install promtool: https://prometheus.io/docs/prometheus/latest/installation/"
    WARNINGS=$((WARNINGS + 1))
    PROMTOOL_AVAILABLE=false
else
    PROMTOOL_AVAILABLE=true
    echo -e "${GREEN}✓ promtool found${NC}"
fi

# Validate Prometheus alert rules
if [ "$PROMTOOL_AVAILABLE" = true ]; then
    echo ""
    echo "Validating Prometheus alert rules..."
    echo "-----------------------------------"
    
    ALERTING_DIR="${REPO_ROOT}/alerting"
    if [ ! -d "$ALERTING_DIR" ]; then
        echo -e "${RED}✗ alerting directory not found${NC}"
        ERRORS=$((ERRORS + 1))
    else
        # Find all YAML files in alerting directory (excluding README and chain subdirectory for now)
        while IFS= read -r -d '' file; do
            echo "Checking: ${file}"
            if ! promtool check rules "$file" 2>&1; then
                echo -e "${RED}✗ Validation failed: ${file}${NC}"
                ERRORS=$((ERRORS + 1))
            else
                echo -e "${GREEN}✓ Valid: ${file}${NC}"
            fi
        done < <(find "$ALERTING_DIR" -maxdepth 1 -name "*.yaml" -type f -print0)
        
        # Also check chain subdirectory if it has YAML files
        if [ -d "${ALERTING_DIR}/chain" ]; then
            while IFS= read -r -d '' file; do
                echo "Checking: ${file}"
                if ! promtool check rules "$file" 2>&1; then
                    echo -e "${RED}✗ Validation failed: ${file}${NC}"
                    ERRORS=$((ERRORS + 1))
                else
                    echo -e "${GREEN}✓ Valid: ${file}${NC}"
                fi
            done < <(find "${ALERTING_DIR}/chain" -name "*.yaml" -type f -print0)
        fi
    fi
fi

# Validate Grafana dashboards
echo ""
echo "Validating Grafana dashboards..."
echo "--------------------------------"

DASHBOARDS_DIR="${REPO_ROOT}/dashboards"
if [ ! -d "$DASHBOARDS_DIR" ]; then
    echo -e "${RED}✗ dashboards directory not found${NC}"
    ERRORS=$((ERRORS + 1))
else
    # Check for jq or python for JSON validation
    if command -v jq &> /dev/null; then
        JSON_VALIDATOR="jq"
        JSON_CMD="jq empty"
    elif command -v python3 &> /dev/null; then
        JSON_VALIDATOR="python3"
        JSON_CMD="python3 -m json.tool"
    elif command -v python &> /dev/null; then
        JSON_VALIDATOR="python"
        JSON_CMD="python -m json.tool"
    else
        echo -e "${YELLOW}Warning: jq or python not found. Using basic JSON syntax check.${NC}"
        WARNINGS=$((WARNINGS + 1))
        JSON_VALIDATOR="basic"
    fi
    
    # Find all JSON files in dashboards directory
    while IFS= read -r -d '' file; do
        echo "Checking: ${file}"
        
        if [ "$JSON_VALIDATOR" = "basic" ]; then
            # Basic check: try to parse as JSON (very basic validation)
            if ! grep -q '"dashboard"' "$file" && ! grep -q '"title"' "$file"; then
                echo -e "${YELLOW}⚠ Warning: ${file} may not be a valid Grafana dashboard${NC}"
                WARNINGS=$((WARNINGS + 1))
            else
                echo -e "${GREEN}✓ Basic check passed: ${file}${NC}"
            fi
        else
            # Full JSON validation
            if $JSON_CMD "$file" > /dev/null 2>&1; then
                echo -e "${GREEN}✓ Valid JSON: ${file}${NC}"
            else
                echo -e "${RED}✗ Invalid JSON: ${file}${NC}"
                $JSON_CMD "$file" > /dev/null 2>&1 || true  # Show error
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done < <(find "$DASHBOARDS_DIR" -name "*.json" -type f -print0)
fi

# Validate Alertmanager configuration
echo ""
echo "Validating Alertmanager configuration..."
echo "----------------------------------------"

ALERTMANAGER_FILE="${REPO_ROOT}/alertmanager/alertmanager.yaml"
if [ ! -f "$ALERTMANAGER_FILE" ]; then
    echo -e "${RED}✗ alertmanager.yaml not found${NC}"
    ERRORS=$((ERRORS + 1))
else
    if [ "$PROMTOOL_AVAILABLE" = true ]; then
        # promtool can also check alertmanager config
        if promtool check config "$ALERTMANAGER_FILE" 2>&1; then
            echo -e "${GREEN}✓ Valid Alertmanager config: ${ALERTMANAGER_FILE}${NC}"
        else
            echo -e "${RED}✗ Validation failed: ${ALERTMANAGER_FILE}${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    else
        # Basic YAML syntax check
        if command -v yamllint &> /dev/null; then
            if yamllint "$ALERTMANAGER_FILE" > /dev/null 2>&1; then
                echo -e "${GREEN}✓ YAML syntax valid: ${ALERTMANAGER_FILE}${NC}"
            else
                echo -e "${RED}✗ YAML syntax error: ${ALERTMANAGER_FILE}${NC}"
                ERRORS=$((ERRORS + 1))
            fi
        else
            echo -e "${YELLOW}⚠ Skipping Alertmanager validation (promtool/yamllint not available)${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All validations passed!${NC}"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠ Validation completed with ${WARNINGS} warning(s)${NC}"
    exit 0
else
    echo -e "${RED}✗ Validation failed with ${ERRORS} error(s) and ${WARNINGS} warning(s)${NC}"
    exit 1
fi
