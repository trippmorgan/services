import os
import json
import time
from pathlib import Path
from flask import Flask, request, jsonify
from faster_whisper import WhisperModel
from waitress import serve
import logging
import google.generativeai as genai

# Set up detailed logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s | %(levelname)-8s | %(message)s'
)

# --- Configuration ---
MODEL_SIZE = "medium.en"
DEVICE = "cuda"
COMPUTE_TYPE = "float16"
CONFIG_DIR = Path("config")

# --- Whisper Initialization ---
try:
    logging.info(f"Loading Whisper model '{MODEL_SIZE}' on device '{DEVICE}'...")
    model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)
    logging.info("Whisper model loaded successfully.")
except Exception as e:
    logging.error(f"Failed to load Whisper model: {e}")
    exit(1)

# --- Gemini Initialization ---
try:
    GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
    if not GOOGLE_API_KEY:
        logging.warning("GOOGLE_API_KEY not set. Gemini features disabled.")
        gemini_model = None
    else:
        genai.configure(api_key=GOOGLE_API_KEY)
        gemini_model = genai.GenerativeModel('gemini-1.5-flash')
        logging.info("Gemini model configured successfully.")
except Exception as e:
    logging.error(f"Failed to initialize Gemini: {e}")
    gemini_model = None

# --- Load Macro Templates ---
try:
    with open(CONFIG_DIR / "macros.json", "r") as f:
        MACRO_TEMPLATES = json.load(f)
    logging.info(f"Loaded {len(MACRO_TEMPLATES)} macro templates.")
except Exception as e:
    logging.error(f"Could not load macro templates: {e}")
    MACRO_TEMPLATES = {}

app = Flask(__name__)

@app.route("/")
def health_check():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "whisper_model": MODEL_SIZE,
        "device": DEVICE,
        "gemini_enabled": gemini_model is not None,
        "macros_loaded": len(MACRO_TEMPLATES)
    })

@app.route("/transcribe", methods=["POST"])
def transcribe():
    """Transcribe audio using Whisper"""
    if "file" not in request.files:
        return jsonify({"error": "No audio file provided"}), 400
    
    file = request.files["file"]
    start_time = time.time()
    
    try:
        logging.info("Received audio file, starting transcription...")
        segments, info = model.transcribe(file, beam_size=5)
        
        # Collect segments with timing info
        segment_list = []
        for seg in segments:
            segment_list.append({
                "text": seg.text,
                "start": seg.start,
                "end": seg.end
            })
        
        transcribed_text = " ".join([seg["text"] for seg in segment_list]).strip()
        duration = time.time() - start_time
        
        logging.info(f"Transcription complete in {duration:.2f}s: {transcribed_text}")
        
        return jsonify({
            "text": transcribed_text,
            "segments": segment_list,
            "language": info.language,
            "duration": info.duration,
            "processing_time": duration
        })
    except Exception as e:
        logging.error(f"Transcription error: {e}", exc_info=True)
        return jsonify({"error": "Failed to process audio"}), 500

@app.route("/process_note", methods=["POST"])
def process_note():
    """Process note with Gemini - now with confidence scores and fallback"""
    if not gemini_model:
        return jsonify({"error": "Gemini is not configured"}), 500

    data = request.get_json()
    if not data or "text" not in data or "macro_key" not in data:
        return jsonify({"error": "Missing 'text' or 'macro_key'"}), 400

    raw_text = data["text"]
    macro_key = data["macro_key"]
    
    if macro_key not in MACRO_TEMPLATES:
        return jsonify({"error": f"Macro '{macro_key}' not found"}), 404

    template_text = MACRO_TEMPLATES[macro_key]
    start_time = time.time()

    # Enhanced prompt with confidence scoring
    prompt = f"""You are an expert medical scribe with advanced entity extraction capabilities.

TASK: Extract structured information from dictated medical text and fill template placeholders.

DICTATED TEXT:
---
{raw_text}
---

TEMPLATE TO FILL:
---
{template_text}
---

INSTRUCTIONS:
1. Identify all placeholders in the template (format: {{field_name}})
2. Extract corresponding information from the dictated text
3. Assign a confidence score (0.0-1.0) for each extraction:
   - 1.0: Explicitly stated, unambiguous
   - 0.8-0.9: Clearly implied or paraphrased
   - 0.5-0.7: Inferred from context
   - 0.0-0.4: Uncertain or not found
4. If information is not found, use empty string with confidence 0.0

OUTPUT FORMAT (JSON only, no markdown):
{{
  "field_name": {{
    "value": "extracted text",
    "confidence": 0.95
  }},
  "another_field": {{
    "value": "another value",
    "confidence": 0.85
  }}
}}

Respond ONLY with valid JSON. No explanations, no markdown formatting."""

    try:
        logging.info(f"Sending note to Gemini for macro '{macro_key}'...")
        response = gemini_model.generate_content(prompt)
        
        # Clean and parse response
        cleaned_json = response.text.strip()
        for marker in ["```json", "```"]:
            cleaned_json = cleaned_json.replace(marker, "")
        cleaned_json = cleaned_json.strip()
        
        filled_json = json.loads(cleaned_json)
        duration = time.time() - start_time
        
        # Log confidence scores
        low_confidence = [
            field for field, data in filled_json.items() 
            if isinstance(data, dict) and data.get("confidence", 0) < 0.7
        ]
        
        if low_confidence:
            logging.warning(f"Low confidence fields: {', '.join(low_confidence)}")
        
        logging.info(f"Gemini processing complete in {duration:.2f}s")
        
        return jsonify({
            "fields": filled_json,
            "metadata": {
                "processing_time": duration,
                "macro_key": macro_key,
                "low_confidence_count": len(low_confidence)
            }
        })
        
    except json.JSONDecodeError as e:
        logging.error(f"JSON parsing error: {e}")
        logging.error(f"Raw response: {response.text}")
        
        # Fallback: try to extract simple key-value pairs
        try:
            fallback_result = _fallback_extraction(raw_text, template_text)
            duration = time.time() - start_time
            
            return jsonify({
                "fields": fallback_result,
                "metadata": {
                    "processing_time": duration,
                    "macro_key": macro_key,
                    "fallback_used": True
                }
            })
        except Exception as fallback_error:
            logging.error(f"Fallback also failed: {fallback_error}")
            return jsonify({"error": "Failed to process note"}), 500
            
    except Exception as e:
        logging.error(f"Gemini processing error: {e}", exc_info=True)
        return jsonify({"error": str(e)}), 500

def _fallback_extraction(text: str, template: str) -> dict:
    """Simple regex-based fallback when Gemini fails"""
    import re
    
    # Extract all placeholders from template
    placeholders = re.findall(r'\{(\w+)\}', template)
    
    result = {}
    for field in placeholders:
        # Try to find the field mentioned explicitly
        pattern = rf'\b{field}\b[:\s]+([^.]+)'
        match = re.search(pattern, text, re.IGNORECASE)
        
        if match:
            result[field] = {
                "value": match.group(1).strip(),
                "confidence": 0.5  # Low confidence for regex extraction
            }
        else:
            result[field] = {
                "value": "",
                "confidence": 0.0
            }
    
    logging.info(f"Fallback extraction completed for {len(result)} fields")
    return result

@app.route("/validate_macro/<macro_key>")
def validate_macro(macro_key):
    """Validate a macro and return its fields"""
    import re
    
    if macro_key not in MACRO_TEMPLATES:
        return jsonify({"error": f"Macro '{macro_key}' not found"}), 404
    
    template = MACRO_TEMPLATES[macro_key]
    placeholders = re.findall(r'\{(\w+)\}', template)
    
    return jsonify({
        "macro_key": macro_key,
        "fields": placeholders,
        "field_count": len(placeholders),
        "template_length": len(template)
    })

@app.route("/list_macros")
def list_macros():
    """List all available macros"""
    return jsonify({
        "macros": list(MACRO_TEMPLATES.keys()),
        "count": len(MACRO_TEMPLATES)
    })

if __name__ == "__main__":
    logging.info("=" * 60)
    logging.info("Dragon Dictation Pro - Enhanced GPU Server")
    logging.info(f"Whisper: {MODEL_SIZE} ({DEVICE}, {COMPUTE_TYPE})")
    logging.info(f"Gemini: {'Enabled' if gemini_model else 'Disabled'}")
    logging.info(f"Macros: {len(MACRO_TEMPLATES)} loaded")
    logging.info("=" * 60)
    serve(app, host="0.0.0.0", port=5005)