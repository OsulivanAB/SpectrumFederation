/**
 * SpectrumFederation Google Sheets Sync - Apps Script
 * 
 * This script receives data from the SpectrumFederation addon and updates a Google Sheet.
 * 
 * SETUP:
 * 1. Open your Google Sheet
 * 2. Go to Extensions > Apps Script
 * 3. Delete any default code
 * 4. Paste this entire file
 * 5. Update the SHEET_NAME constant below to match your sheet tab name
 * 6. Click Deploy > New deployment
 * 7. Select "Web app"
 * 8. Execute as: Me
 * 9. Who has access: Anyone
 * 10. Click Deploy
 * 11. Copy the Web App URL - this is your API_URL for the Python script
 * 
 * CONFIGURATION:
 */

// The name of the sheet tab to update (e.g., "Sheet1", "Loot Tracker", etc.)
// TODO: Update this to match your sheet tab name
const SHEET_NAME = "Sheet1";

// WoW class colors (hex format)
const CLASS_COLORS = {
  'DEATHKNIGHT': '#C41E3A',
  'DEMONHUNTER': '#A330C9',
  'DRUID': '#FF7C0A',
  'EVOKER': '#33937F',
  'HUNTER': '#AAD372',
  'MAGE': '#3FC7EB',
  'MONK': '#00FF98',
  'PALADIN': '#F48CBA',
  'PRIEST': '#FFFFFF',
  'ROGUE': '#FFF468',
  'SHAMAN': '#0070DD',
  'WARLOCK': '#8788EE',
  'WARRIOR': '#C69B6D',
};

/**
 * Convert hex color to RGB object for Google Sheets API
 */
function hexToRgb(hex) {
  hex = hex.replace('#', '');
  return {
    red: parseInt(hex.substring(0, 2), 16) / 255,
    green: parseInt(hex.substring(2, 4), 16) / 255,
    blue: parseInt(hex.substring(4, 6), 16) / 255
  };
}

/**
 * Handle POST requests from the Python script
 */
function doPost(e) {
  try {
    // Parse the incoming JSON data
    const data = JSON.parse(e.postData.contents);
    
    // Validate required fields
    if (!data.members || !Array.isArray(data.members)) {
      return ContentService.createTextOutput(JSON.stringify({
        success: false,
        error: "Missing or invalid 'members' array"
      })).setMimeType(ContentService.MimeType.JSON);
    }
    
    // Update the sheet
    updateSheet(data);
    
    return ContentService.createTextOutput(JSON.stringify({
      success: true,
      message: `Updated sheet with ${data.members.length} members`
    })).setMimeType(ContentService.MimeType.JSON);
    
  } catch (error) {
    return ContentService.createTextOutput(JSON.stringify({
      success: false,
      error: error.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

/**
 * Handle GET requests (for testing)
 */
function doGet(e) {
  return ContentService.createTextOutput(JSON.stringify({
    success: true,
    message: "SpectrumFederation Sync API is running",
    version: "2.0",
    method: "POST data to this URL with member information"
  })).setMimeType(ContentService.MimeType.JSON);
}

/**
 * Update the Google Sheet with member data
 */
function updateSheet(data) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(SHEET_NAME);
  
  // Create sheet if it doesn't exist
  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
  }
  
  // Clear existing content
  sheet.clear();
  
  const pointName = data.pointName || "Points";
  const equipmentSlots = data.equipmentSlots || [];
  const members = data.members || [];
  
  // Build header row
  const headers = ["Player Name", pointName, ...equipmentSlots];
  
  // Build data rows
  const rows = [headers];
  members.forEach(member => {
    const row = [
      member.name,
      member.points,
      ...equipmentSlots.map(slot => member.equipment[slot] ? "✅" : "❌")
    ];
    rows.push(row);
  });
  
  // Write all data at once
  if (rows.length > 0) {
    sheet.getRange(1, 1, rows.length, headers.length).setValues(rows);
  }
  
  // Apply formatting
  applyFormatting(sheet, members, headers.length);
}

/**
 * Apply formatting to the sheet
 */
function applyFormatting(sheet, members, numColumns) {
  // Header row formatting: Arial 10, bold, white text, dark gray background
  const headerRange = sheet.getRange(1, 1, 1, numColumns);
  headerRange.setBackground('#434343')
            .setFontColor('#FFFFFF')
            .setFontFamily('Arial')
            .setFontSize(10)
            .setFontWeight('bold');
  
  if (members.length === 0) return;
  
  // Player names (Column A): class-colored text, dark gray background, bold
  const nameRange = sheet.getRange(2, 1, members.length, 1);
  nameRange.setBackground('#434343')
           .setFontFamily('Arial')
           .setFontSize(10)
           .setFontWeight('bold');
  
  // Apply individual class colors to each name
  members.forEach((member, index) => {
    const className = (member.class || 'WARRIOR').toUpperCase();
    const color = CLASS_COLORS[className] || '#FFFFFF';
    sheet.getRange(index + 2, 1).setFontColor(color);
  });
  
  // Points column (Column B): white text, gray background
  const pointsRange = sheet.getRange(2, 2, members.length, 1);
  pointsRange.setBackground('#b7b7b7')
             .setFontColor('#FFFFFF')
             .setFontFamily('Arial')
             .setFontSize(10)
             .setFontWeight('normal');
  
  // Auto-resize columns for better display
  for (let i = 1; i <= numColumns; i++) {
    sheet.autoResizeColumn(i);
  }
}

/**
 * Test function - run this to verify the script works
 * (Run this from the Apps Script editor)
 */
function testUpdate() {
  const testData = {
    pointName: "DKP",
    equipmentSlots: ["Head", "Neck", "Shoulder", "Chest", "Weapon"],
    members: [
      {
        name: "TestPlayer1",
        class: "MAGE",
        points: 100,
        equipment: {
          "Head": true,
          "Neck": false,
          "Shoulder": true,
          "Chest": true,
          "Weapon": false
        }
      },
      {
        name: "TestPlayer2",
        class: "WARRIOR",
        points: 75,
        equipment: {
          "Head": false,
          "Neck": true,
          "Shoulder": false,
          "Chest": true,
          "Weapon": true
        }
      }
    ]
  };
  
  updateSheet(testData);
  Logger.log("Test update completed successfully!");
}
