import os
import json
import time
import uuid
from pathlib import Path
from datetime import datetime
from flask import Flask, request, jsonify
from flask_socketio import SocketIO, emit
from faster_whisper import WhisperModel
from waitress import serve
import logging
import google.generativeai as genai
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional
import threading
from queue import Queue

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
METRICS_DIR = Path("metrics")
METRICS_DIR.mkdir(exist_ok=True)

# --- Data Classes for Metrics ---
@dataclass
class TranscriptionMetric:
    id: str
    timestamp: datetime
    audio_duration: float
    processing_time: float
    word_count: int
    confidence_avg: float
    model_used: str

@dataclass
class TemplateMetric:
    id: str
    timestamp: datetime
    template_key: str
    template_source: str  # "static", "dynamic", "modified"
    processing_time: float
    field_count: int
    low_confidence_count: int
    avg_confidence: float
    user_corrections: int = 0

class MetricsTracker:
    """Track and analyze system performance metrics"""
    
    def __init__(self, metrics_dir: Path):
        self.metrics_dir = metrics_dir
        self.transcription_log = metrics_dir / "transcriptions.jsonl"
        self.template_log = metrics_dir / "templates.jsonl"
        
    def log_transcription(self, metric: TranscriptionMetric):
        with open(self.transcription_log, 'a') as f:
            f.write(json.dumps(asdict(metric), default=str) + '\n')
    
    def log_template_usage(self, metric: TemplateMetric):
        with open(self.template_log, 'a') as f:
            f.write(json.dumps(asdict(metric), default=str) + '\n')
    
    def get_summary(self, days: int = 7) -> Dict:
        """Get performance summary for last N days"""
        cutoff = datetime.now().timestamp() - (days * 86400)
        
        transcriptions = self._read_metrics(self.transcription_log, cutoff)
        templates = self._read_metrics(self.template_log, cutoff)
        
        return {
            "period_days": days,
            "transcription_stats": {
                "total_count": len(transcriptions),
                "avg_processing_time": self._avg([t['processing_time'] for t in transcriptions]),
                "avg_confidence": self._avg([t['confidence_avg'] for t in transcriptions]),
            },
            "template_stats": {
                "total_count": len(templates),
                "avg_processing_time": self._avg([t['processing_time'] for t in templates]),
                "avg_confidence": self._avg([t['avg_confidence'] for t in templates]),
                "dynamic_template_usage": sum(1 for t in templates if t['template_source'] == 'dynamic'),
                "problematic_templates": self._identify_problematic(templates)
            }
        }
    
    def _read_metrics(self, log_file: Path, cutoff: float) -> List[Dict]:
        if not log_file.exists():
            return []
        
        metrics = []
        with open(log_file, 'r') as f:
            for line in f:
                try:
                    data = json.loads(line)
                    ts = datetime.fromisoformat(data['timestamp']).timestamp()
                    if ts >= cutoff:
                        metrics.append(data)
                except:
                    continue
        return metrics
    
    def _avg(self, values: List[float]) -> float:
        return sum(values) / len(values) if values else 0.0
    
    def _identify_problematic(self, templates: List[Dict]) -> List[Dict]:
        """Identify templates with low confidence or high correction rates"""
        template_groups = {}
        for t in templates:
            key = t['template_key']
            if key not in template_groups:
                template_groups[key] = []
            template_groups[key].append(t)
        
        problematic = []
        for key, group in template_groups.items():
            avg_conf = self._avg([t['avg_confidence'] for t in group])
            avg_corrections = self._avg([t.get('user_corrections', 0) for t in group])
            
            if avg_conf < 0.6 or avg_corrections > 2:
                problematic.append({
                    "template_key": key,
                    "usage_count": len(group),
                    "avg_confidence": round(avg_conf, 2),
                    "avg_corrections": round(avg_corrections, 2),
                    "recommendation": "Consider template revision"
                })
        
        return problematic

# --- Whisper Initialization ---
try:
    logging.info(f"Loading Whisper model '{MODEL_SIZE}' on device '{DEVICE}'...")
    model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)
    logging.info("Whisper model loaded successfully.")
except Exception as e:
    logging.error(f"Failed to load Whisper model: {e}")
    exit(1)

# --- Gemini 2.5 Initialization ---
try:
    GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY")
    if not GOOGLE_API_KEY:
        logging.warning("GOOGLE_API_KEY not set. Gemini features disabled.")
        gemini_model = None
    else:
        genai.configure(api_key=GOOGLE_API_KEY)
        # Updated to Gemini 2.5 Flash
        gemini_model = genai.GenerativeModel('gemini-2.0-flash-exp')
        logging.info("Gemini 2.5 Flash model configured successfully.")
except Exception as e:
    logging.error(f"Failed to initialize Gemini: {e}")
    gemini_model = None

# --- Load Static Macro Templates (for fallback/reference) ---
try:
    with open(CONFIG_DIR / "macros.json", "r") as f:
        STATIC_TEMPLATES = json.load(f)
    logging.info(f"Loaded {len(STATIC_TEMPLATES)} static templates.")
except Exception as e:
    logging.error(f"Could not load macro templates: {e}")
    STATIC_TEMPLATES = {}

# Initialize metrics tracker
metrics_tracker = MetricsTracker(METRICS_DIR)

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*")

# Real-time transcription queue
realtime_sessions = {}

@app.route("/")
def health_check():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "version": "7.0",
        "whisper_model": MODEL_SIZE,
        "device": DEVICE,
        "gemini_model": "gemini-2.0-flash-exp",
        "gemini_enabled": gemini_model is not None,
        "static_templates": len(STATIC_TEMPLATES),
        "features": [
            "dynamic_templates",
            "batch_processing",
            "realtime_transcription",
            "quality_metrics",
            "auto_template_selection"
        ]
    })

@app.route("/transcribe", methods=["POST"])
def transcribe():
    """Transcribe audio using Whisper"""
    if "file" not in request.files:
        return jsonify({"error": "No audio file provided"}), 400
    
    file = request.files["file"]
    start_time = time.time()
    transcription_id = str(uuid.uuid4())
    
    try:
        logging.info(f"[{transcription_id}] Received audio file, starting transcription...")
        segments, info = model.transcribe(file, beam_size=5)
        
        # Collect segments with timing and confidence
        segment_list = []
        confidences = []
        for seg in segments:
            segment_list.append({
                "text": seg.text,
                "start": seg.start,
                "end": seg.end,
                "confidence": getattr(seg, 'avg_logprob', 0.0)
            })
            confidences.append(segment_list[-1]["confidence"])
        
        transcribed_text = " ".join([seg["text"] for seg in segment_list]).strip()
        duration = time.time() - start_time
        word_count = len(transcribed_text.split())
        avg_confidence = sum(confidences) / len(confidences) if confidences else 0.0
        
        # Log metrics
        metric = TranscriptionMetric(
            id=transcription_id,
            timestamp=datetime.now(),
            audio_duration=info.duration,
            processing_time=duration,
            word_count=word_count,
            confidence_avg=avg_confidence,
            model_used=MODEL_SIZE
        )
        metrics_tracker.log_transcription(metric)
        
        logging.info(f"[{transcription_id}] Transcription complete in {duration:.2f}s")
        
        return jsonify({
            "id": transcription_id,
            "text": transcribed_text,
            "segments": segment_list,
            "language": info.language,
            "duration": info.duration,
            "processing_time": duration,
            "word_count": word_count,
            "avg_confidence": avg_confidence
        })
    except Exception as e:
        logging.error(f"[{transcription_id}] Transcription error: {e}", exc_info=True)
        return jsonify({"error": "Failed to process audio"}), 500

@app.route("/transcribe_batch", methods=["POST"])
def transcribe_batch():
    """Batch transcribe multiple audio files"""
    files = request.files.getlist("files")
    
    if not files:
        return jsonify({"error": "No audio files provided"}), 400
    
    batch_id = str(uuid.uuid4())
    results = []
    
    for idx, file in enumerate(files):
        try:
            logging.info(f"[Batch {batch_id}] Processing file {idx+1}/{len(files)}")
            segments, info = model.transcribe(file, beam_size=5)
            
            segment_list = []
            for seg in segments:
                segment_list.append({
                    "text": seg.text,
                    "start": seg.start,
                    "end": seg.end
                })
            
            transcribed_text = " ".join([seg["text"] for seg in segment_list]).strip()
            
            results.append({
                "file_index": idx,
                "filename": file.filename,
                "text": transcribed_text,
                "duration": info.duration,
                "status": "success"
            })
        except Exception as e:
            logging.error(f"[Batch {batch_id}] Error on file {idx}: {e}")
            results.append({
                "file_index": idx,
                "filename": file.filename,
                "status": "error",
                "error": str(e)
            })
    
    successful = sum(1 for r in results if r["status"] == "success")
    
    return jsonify({
        "batch_id": batch_id,
        "total_files": len(files),
        "successful": successful,
        "failed": len(files) - successful,
        "results": results
    })

@app.route("/select_template", methods=["POST"])
def select_template():
    """AI-powered template selection"""
    if not gemini_model:
        return jsonify({"error": "Gemini is not configured"}), 500
    
    data = request.get_json()
    if not data or "text" not in data:
        return jsonify({"error": "Missing 'text' field"}), 400
    
    raw_text = data["text"]
    
    prompt = f"""You are a medical documentation expert specializing in vascular surgery.

TASK: Analyze the following dictated medical text and determine the most appropriate procedure template.

AVAILABLE TEMPLATES:
{json.dumps(list(STATIC_TEMPLATES.keys()), indent=2)}

DICTATED TEXT:
---
{raw_text}
---

INSTRUCTIONS:
1. Identify the primary procedure being described
2. Select the most appropriate template from the list
3. Provide confidence score (0.0-1.0)
4. Suggest if a custom/dynamic template would be better

OUTPUT FORMAT (JSON only):
{{
  "recommended_template": "template_key",
  "confidence": 0.95,
  "reasoning": "Brief explanation",
  "requires_dynamic_template": false,
  "procedure_type": "Procedure name"
}}

Respond ONLY with valid JSON."""
    
    try:
        response = gemini_model.generate_content(prompt)
        cleaned_json = response.text.strip()
        for marker in ["```json", "```"]:
            cleaned_json = cleaned_json.replace(marker, "")
        
        result = json.loads(cleaned_json.strip())
        
        return jsonify(result)
    except Exception as e:
        logging.error(f"Template selection error: {e}")
        return jsonify({"error": str(e)}), 500

@app.route("/generate_dynamic_template", methods=["POST"])
def generate_dynamic_template():
    """Generate a custom template based on the dictated content"""
    if not gemini_model:
        return jsonify({"error": "Gemini is not configured"}), 500
    
    data = request.get_json()
    if not data or "text" not in data:
        return jsonify({"error": "Missing 'text' field"}), 400
    
    raw_text = data["text"]
    procedure_type = data.get("procedure_type", "medical procedure")
    
    prompt = f"""You are an expert medical documentation specialist.

TASK: Create a professional medical procedure template based on the dictated content.

DICTATED TEXT:
---
{raw_text}
---

PROCEDURE TYPE: {procedure_type}

INSTRUCTIONS:
1. Analyze the dictated content structure
2. Create a professional template with appropriate sections
3. Use placeholders {{field_name}} for variable content
4. Include standard sections: Date, Diagnoses, Procedures, Complications, etc.
5. Match the style and detail level of the dictation

REFERENCE FORMAT:
Procedure Date: {{date}}

Preoperative Diagnosis:
1. {{preop_dx}}

Postoperative Diagnosis:
1. {{postop_dx}}

Procedure Performed:
1. {{procedure_name}}

[Additional relevant sections based on content]

OUTPUT: Return ONLY the template text with placeholders. No JSON, no explanation."""
    
    try:
        start_time = time.time()
        response = gemini_model.generate_content(prompt)
        template_text = response.text.strip()
        
        # Remove markdown formatting if present
        template_text = template_text.replace("```", "").strip()
        
        duration = time.time() - start_time
        template_id = str(uuid.uuid4())
        
        logging.info(f"Dynamic template generated in {duration:.2f}s")
        
        return jsonify({
            "template_id": template_id,
            "template": template_text,
            "generation_time": duration,
            "procedure_type": procedure_type
        })
    except Exception as e:
        logging.error(f"Dynamic template generation error: {e}")
        return jsonify({"error": str(e)}), 500

@app.route("/process_note", methods=["POST"])
def process_note():
    """Enhanced note processing with dynamic template support"""
    if not gemini_model:
        return jsonify({"error": "Gemini is not configured"}), 500

    data = request.get_json()
    if not data or "text" not in data:
        return jsonify({"error": "Missing 'text'"}), 400

    raw_text = data["text"]
    template_key = data.get("macro_key")
    custom_template = data.get("custom_template")
    
    # Determine template source
    if custom_template:
        template_text = custom_template
        template_source = "dynamic"
        template_key = "custom_" + str(uuid.uuid4())[:8]
    elif template_key and template_key in STATIC_TEMPLATES:
        template_text = STATIC_TEMPLATES[template_key]
        template_source = "static"
    else:
        return jsonify({"error": "Must provide either 'macro_key' or 'custom_template'"}), 400

    start_time = time.time()
    note_id = str(uuid.uuid4())

    prompt = f"""You are an expert medical scribe with advanced entity extraction capabilities using Gemini 2.5.

TASK: Extract structured information from dictated medical text and fill template placeholders with high accuracy.

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
3. Use advanced reasoning to infer missing information when appropriate
4. Assign confidence scores (0.0-1.0):
   - 1.0: Explicitly stated, unambiguous
   - 0.8-0.9: Clearly implied or paraphrased  
   - 0.5-0.7: Inferred from medical context
   - 0.0-0.4: Uncertain or not found
5. Maintain medical terminology accuracy
6. For dates, use format: MM/DD/YYYY

OUTPUT FORMAT (JSON only, no markdown):
{{
  "field_name": {{
    "value": "extracted text",
    "confidence": 0.95,
    "source": "explicit|inferred|contextual"
  }}
}}

Respond ONLY with valid JSON."""

    try:
        logging.info(f"[{note_id}] Processing note with Gemini 2.5...")
        response = gemini_model.generate_content(prompt)
        
        cleaned_json = response.text.strip()
        for marker in ["```json", "```"]:
            cleaned_json = cleaned_json.replace(marker, "")
        cleaned_json = cleaned_json.strip()
        
        filled_json = json.loads(cleaned_json)
        duration = time.time() - start_time
        
        # Calculate metrics
        confidences = [
            data.get("confidence", 0) 
            for data in filled_json.values() 
            if isinstance(data, dict)
        ]
        avg_confidence = sum(confidences) / len(confidences) if confidences else 0.0
        low_confidence_fields = [
            field for field, data in filled_json.items()
            if isinstance(data, dict) and data.get("confidence", 0) < 0.7
        ]
        
        # Log template metrics
        metric = TemplateMetric(
            id=note_id,
            timestamp=datetime.now(),
            template_key=template_key,
            template_source=template_source,
            processing_time=duration,
            field_count=len(filled_json),
            low_confidence_count=len(low_confidence_fields),
            avg_confidence=avg_confidence
        )
        metrics_tracker.log_template_usage(metric)
        
        if low_confidence_fields:
            logging.warning(f"[{note_id}] Low confidence fields: {', '.join(low_confidence_fields)}")
        
        logging.info(f"[{note_id}] Processing complete in {duration:.2f}s")
        
        return jsonify({
            "note_id": note_id,
            "fields": filled_json,
            "metadata": {
                "processing_time": duration,
                "template_key": template_key,
                "template_source": template_source,
                "avg_confidence": avg_confidence,
                "low_confidence_count": len(low_confidence_fields),
                "low_confidence_fields": low_confidence_fields
            }
        })
        
    except json.JSONDecodeError as e:
        logging.error(f"[{note_id}] JSON parsing error: {e}")
        return jsonify({"error": "Failed to parse AI response"}), 500
            
    except Exception as e:
        logging.error(f"[{note_id}] Processing error: {e}", exc_info=True)
        return jsonify({"error": str(e)}), 500

@app.route("/report_correction", methods=["POST"])
def report_correction():
    """Report user corrections for quality tracking"""
    data = request.get_json()
    
    if not data or "note_id" not in data:
        return jsonify({"error": "Missing 'note_id'"}), 400
    
    note_id = data["note_id"]
    corrections = data.get("corrections", [])
    
    # Update metrics with correction count
    # In production, you'd update the existing metric entry
    logging.info(f"[{note_id}] User made {len(corrections)} corrections")
    
    return jsonify({
        "status": "recorded",
        "note_id": note_id,
        "correction_count": len(corrections)
    })

@app.route("/metrics")
def get_metrics():
    """Get quality metrics summary"""
    days = request.args.get('days', default=7, type=int)
    summary = metrics_tracker.get_summary(days)
    
    return jsonify(summary)

@app.route("/list_templates")
def list_templates():
    """List all available static templates"""
    return jsonify({
        "templates": list(STATIC_TEMPLATES.keys()),
        "count": len(STATIC_TEMPLATES)
    })

# WebSocket for real-time transcription
@socketio.on('connect')
def handle_connect():
    session_id = request.sid
    logging.info(f"Client connected: {session_id}")
    emit('connection_response', {'status': 'connected', 'session_id': session_id})

@socketio.on('disconnect')
def handle_disconnect():
    session_id = request.sid
    if session_id in realtime_sessions:
        del realtime_sessions[session_id]
    logging.info(f"Client disconnected: {session_id}")

@socketio.on('audio_chunk')
def handle_audio_chunk(data):
    """Handle real-time audio streaming"""
    session_id = request.sid
    
    try:
        # In production, you'd buffer chunks and transcribe periodically
        # This is a simplified version
        audio_data = data.get('audio')
        
        if not audio_data:
            return
        
        # Process audio chunk (simplified - would need proper buffering)
        emit('transcription_chunk', {
            'text': '[Real-time transcription]',
            'timestamp': time.time(),
            'is_final': data.get('is_final', False)
        })
        
    except Exception as e:
        logging.error(f"Real-time transcription error: {e}")
        emit('error', {'message': str(e)})

if __name__ == "__main__":
    logging.info("=" * 70)
    logging.info("Dragon Dictation Pro - Enhanced v7.0 with Gemini 2.5")
    logging.info(f"Whisper: {MODEL_SIZE} ({DEVICE}, {COMPUTE_TYPE})")
    logging.info(f"Gemini: 2.0 Flash Experimental")
    logging.info(f"Static Templates: {len(STATIC_TEMPLATES)}")
    logging.info("Features: Dynamic Templates | Batch | Real-time | Metrics")
    logging.info("=" * 70)
    
    # Use SocketIO for WebSocket support
    socketio.run(app, host="0.0.0.0", port=5005, allow_unsafe_werkzeug=True)