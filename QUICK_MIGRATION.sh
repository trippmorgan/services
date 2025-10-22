#!/bin/bash
# Dragon Dictation Pro v7.0 Migration Script
# Run on joevoldemort via Tailscale
# Usage: bash QUICK_MIGRATION.sh

set -e  # Exit on error

echo "=============================================="
echo "Dragon Dictation Pro v6.0 → v7.0 Migration"
echo "=============================================="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Navigate to services directory
cd ~/services || { echo "Error: ~/services directory not found"; exit 1; }

echo -e "${YELLOW}[1/10] Creating backups...${NC}"
# Backup database
BACKUP_FILE="backup_v6_$(date +%Y%m%d_%H%M%S).sql"
docker exec central_postgres_db pg_dump -U postgres surgical_command_center > "$BACKUP_FILE"
echo -e "${GREEN}✓ Database backed up to: $BACKUP_FILE${NC}"

# Backup configuration files
cp docker-compose.yml docker-compose.yml.backup
cp .env .env.backup
cp dragon_dictation_pro/dragon_gpu_server.py dragon_dictation_pro/dragon_gpu_server.py.v6.backup
echo -e "${GREEN}✓ Configuration files backed up${NC}"

# Save current image info
docker images | grep dragon_dictation > current_image.txt
echo -e "${GREEN}✓ Current image info saved${NC}"
echo ""

echo -e "${YELLOW}[2/10] Verifying backup integrity...${NC}"
if [ -s "$BACKUP_FILE" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo -e "${GREEN}✓ Backup successful: $BACKUP_SIZE${NC}"
else
    echo -e "${RED}✗ Backup failed! Aborting migration.${NC}"
    exit 1
fi
echo ""

echo -e "${YELLOW}[3/10] Checking for new files...${NC}"
# Check if v7.0 files are in place
if [ ! -f "database_schema.sql" ]; then
    echo -e "${RED}✗ database_schema.sql not found!${NC}"
    echo "Please copy the new database_schema.sql to ~/services/"
    exit 1
fi
echo -e "${GREEN}✓ database_schema.sql found${NC}"

# Verify updated server file
if grep -q "version.*7.0" dragon_dictation_pro/dragon_gpu_server.py; then
    echo -e "${GREEN}✓ v7.0 server code detected${NC}"
else
    echo -e "${YELLOW}⚠ Warning: Server code may not be v7.0${NC}"
    echo "Continue anyway? (y/n)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
echo ""

echo -e "${YELLOW}[4/10] Stopping current services...${NC}"
docker-compose down --timeout 10
echo -e "${GREEN}✓ Services stopped${NC}"
echo ""

echo -e "${YELLOW}[5/10] Building v7.0 image...${NC}"
docker-compose build --no-cache dragon_dictation
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ v7.0 image built successfully${NC}"
else
    echo -e "${RED}✗ Build failed! Check errors above.${NC}"
    exit 1
fi
echo ""

echo -e "${YELLOW}[6/10] Starting PostgreSQL...${NC}"
docker-compose up -d postgres
echo "Waiting for PostgreSQL to be ready..."
sleep 10

# Wait for PostgreSQL
MAX_ATTEMPTS=30
ATTEMPT=0
until docker exec central_postgres_db pg_isready -U postgres > /dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT+1))
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo -e "${RED}✗ PostgreSQL failed to start${NC}"
        exit 1
    fi
    echo -n "."
    sleep 2
done
echo ""
echo -e "${GREEN}✓ PostgreSQL is ready${NC}"
echo ""

echo -e "${YELLOW}[7/10] Applying v7.0 database schema...${NC}"
docker exec -i central_postgres_db psql -U postgres -d surgical_command_center < database_schema.sql
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Schema updated successfully${NC}"
else
    echo -e "${RED}✗ Schema update failed!${NC}"
    echo "Rollback? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "Rolling back database..."
        docker exec -i central_postgres_db psql -U postgres surgical_command_center < "$BACKUP_FILE"
        echo "Database rolled back. Please investigate errors."
    fi
    exit 1
fi
echo ""

echo -e "${YELLOW}[8/10] Starting v7.0 services...${NC}"
docker-compose up -d
echo "Waiting for services to start..."
sleep 15
echo -e "${GREEN}✓ Services started${NC}"
echo ""

echo -e "${YELLOW}[9/10] Verifying v7.0 deployment...${NC}"

# Check container status
if docker ps | grep -q "dragon_ai_service.*Up"; then
    echo -e "${GREEN}✓ Dragon service is running${NC}"
else
    echo -e "${RED}✗ Dragon service not running!${NC}"
    docker-compose logs --tail=50 dragon_dictation
    exit 1
fi

# Check health endpoint
echo "Testing health endpoint..."
sleep 5
HEALTH_RESPONSE=$(curl -s http://localhost:5005/ || echo "failed")

if echo "$HEALTH_RESPONSE" | grep -q '"version": "7.0"'; then
    echo -e "${GREEN}✓ v7.0 is responding correctly${NC}"
else
    echo -e "${YELLOW}⚠ Warning: Health check didn't confirm v7.0${NC}"
    echo "Response: $HEALTH_RESPONSE"
    echo "Check logs? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        docker-compose logs --tail=50 dragon_dictation
    fi
fi
echo ""

echo -e "${YELLOW}[10/10] Testing new v7.0 features...${NC}"

# Test metrics endpoint
METRICS_RESPONSE=$(curl -s http://localhost:5005/metrics?days=7 || echo "failed")
if echo "$METRICS_RESPONSE" | grep -q "transcription_stats"; then
    echo -e "${GREEN}✓ Metrics endpoint working${NC}"
else
    echo -e "${YELLOW}⚠ Metrics endpoint issue (may need time to populate)${NC}"
fi

# Test list templates
TEMPLATES_RESPONSE=$(curl -s http://localhost:5005/list_templates || echo "failed")
if echo "$TEMPLATES_RESPONSE" | grep -q "templates"; then
    echo -e "${GREEN}✓ Template listing working${NC}"
else
    echo -e "${YELLOW}⚠ Template listing issue${NC}"
fi
echo ""

echo "=============================================="
echo -e "${GREEN}Migration Complete!${NC}"
echo "=============================================="
echo ""
echo "Summary:"
echo "  • Backup: $BACKUP_FILE ($BACKUP_SIZE)"
echo "  • Status: Check with 'docker ps'"
echo "  • Health: curl http://localhost:5005/"
echo "  • Logs: docker-compose logs -f dragon_dictation"
echo ""
echo "Verification commands:"
echo "  curl http://localhost:5005/"
echo "  curl http://localhost:5005/metrics?days=7"
echo "  curl http://localhost:5005/list_templates"
echo ""
echo "If issues occur, rollback with:"
echo "  docker-compose down"
echo "  cp docker-compose.yml.backup docker-compose.yml"
echo "  cp dragon_dictation_pro/dragon_gpu_server.py.v6.backup dragon_dictation_pro/dragon_gpu_server.py"
echo "  docker-compose build dragon_dictation"
echo "  docker-compose up -d"
echo ""

# Final status check
echo "Current container status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

# Offer to show logs
echo "View startup logs? (y/n)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    docker-compose logs --tail=50 dragon_dictation
fi

echo ""
echo -e "${GREEN}🎉 Dragon Dictation Pro v7.0 is now running!${NC}"