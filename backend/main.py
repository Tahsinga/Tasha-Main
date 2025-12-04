# FastAPI backend for Tasha bot
# Put your OPENAI_API_KEY in .env file or environment variable
# Run with: uvicorn main:app --reload --host 0.0.0.0 --port 8000

# Load .env file early (before any os.getenv calls)
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass  # python-dotenv not installed; rely on environment variables directly

import os
import logging
from typing import Optional, List, Dict, Any
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import openai as openai_pkg
from openai import OpenAI
from datetime import datetime, timedelta
from functools import lru_cache
import json

# ============= Configuration =============
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DEFAULT_OPENAI_KEY = os.getenv("OPENAI_API_KEY", "").strip()
if not DEFAULT_OPENAI_KEY:
    logger.warning("OPENAI_API_KEY not set. Set it before deploying to production.")
else:
    logger.info("✓ OPENAI_API_KEY found in environment (not logged for security).")

def get_openai_client(api_key: Optional[str] = None) -> OpenAI:
    """Return an OpenAI client using the provided API key or the environment key.
    This reads `OPENAI_API_KEY` dynamically from os.environ so changes take effect
    after a process restart and avoid stale import-time values.
    """
    key = api_key if api_key else os.getenv("OPENAI_API_KEY", "")
    # Construct a client. If key is empty the client will still be created but
    # calls may fail; callers should handle mock behavior before calling.
    return OpenAI(api_key=key) if key else OpenAI()

# Simple in-memory rate limiting (for production, use Redis)
REQUEST_LIMITS = {}
REQUESTS_PER_MINUTE = 60
REQUESTS_PER_HOUR = 1000

app = FastAPI(title="Tasha Backend", version="1.0.0")

# Configure CORS. Set `ALLOWED_ORIGINS` env var to a comma-separated list
# (e.g. https://example.com,http://10.0.2.2:8000) or leave empty to allow all.
allowed = os.getenv("ALLOWED_ORIGINS", "*")
if allowed.strip() == "*" or allowed.strip() == "":
    origins = ["*"]
else:
    origins = [o.strip() for o in allowed.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ============= Request/Response Models =============
class ChunkRequest(BaseModel):
    chunk: str
    system_prompt: Optional[str] = None
    model: str = "gpt-4o-mini"
    temperature: float = 0.0
    max_tokens: int = 512

class EmbedRequest(BaseModel):
    texts: List[str]
    model: str = "text-embedding-3-small"

class BatchRAGRequest(BaseModel):
    question: str
    chunks: List[Dict[str, Any]]  # list of {text, book, start_page, end_page, ...}
    system_prompt: Optional[str] = None
    model: str = "gpt-4o-mini"
    temperature: float = 0.0
    max_tokens: int = 600
    api_key: Optional[str] = None  # Allow app to pass real API key from Settings

class TrainBookRequest(BaseModel):
    book_id: str
    chunks: List[Dict[str, Any]]
    model: str = "gpt-4o-mini"
    temperature: float = 0.0
    max_tokens: int = 800

# ============= Auth & Rate Limiting =============
def verify_auth(authorization: Optional[str]) -> str:
    """Verify Bearer token. For production, validate against your auth system."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid authorization header")
    token = authorization.split(" ", 1)[1]
    # TODO: Validate token against your auth backend (Firebase, JWT, etc.)
    # For now, just ensure it's not empty
    if not token:
        raise HTTPException(status_code=401, detail="Invalid token")
    return token

def check_rate_limit(user_id: str) -> bool:
    """Simple rate limiting. Replace with Redis for production."""
    now = datetime.now()
    minute_ago = now - timedelta(minutes=1)
    hour_ago = now - timedelta(hours=1)
    
    if user_id not in REQUEST_LIMITS:
        REQUEST_LIMITS[user_id] = []
    
    # Clean old requests
    REQUEST_LIMITS[user_id] = [ts for ts in REQUEST_LIMITS[user_id] if ts > hour_ago]
    
    # Check limits
    recent_minute = [ts for ts in REQUEST_LIMITS[user_id] if ts > minute_ago]
    if len(recent_minute) >= REQUESTS_PER_MINUTE:
        return False
    if len(REQUEST_LIMITS[user_id]) >= REQUESTS_PER_HOUR:
        return False
    
    REQUEST_LIMITS[user_id].append(now)
    return True

# ============= Endpoints =============

@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "ok", "timestamp": datetime.now().isoformat()}

@app.post("/process_chunk")
async def process_chunk(req: ChunkRequest, authorization: str = Header(None)):
    """Process a single chunk with OpenAI."""
    user_id = verify_auth(authorization)
    
    if not check_rate_limit(user_id):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    
    if not req.chunk or len(req.chunk.strip()) == 0:
        raise HTTPException(status_code=400, detail="Chunk cannot be empty")
    
    try:
        logger.info(f"[process_chunk] user={user_id} model={req.model} chunk_len={len(req.chunk)}")
        
        system_prompt = req.system_prompt or "You are a helpful assistant."
        
        # Build OpenAI client (may use api_key passed in request via req.api_key)
        client = get_openai_client(getattr(req, "api_key", None))

        response = client.chat.completions.create(
            model=req.model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": req.chunk}
            ],
            temperature=req.temperature,
            max_tokens=req.max_tokens,
            timeout=30,
        )

        # Response shape follows the Chat Completions format
        answer = response.choices[0].message["content"] if hasattr(response, "choices") else str(response)
        logger.info(f"[process_chunk] success user={user_id}")
        
        return {
            "success": True,
            "result": answer,
            "model": req.model,
            "usage": getattr(response, "usage", {})
        }
    except openai_pkg.APITimeoutError:
        logger.exception(f"[process_chunk] timeout user={user_id}")
        raise HTTPException(status_code=504, detail="OpenAI request timed out")
    except openai_pkg.RateLimitError:
        logger.exception(f"[process_chunk] rate limit user={user_id}")
        raise HTTPException(status_code=429, detail="OpenAI rate limit hit")
    except Exception as e:
        logger.exception(f"[process_chunk] error user={user_id} {str(e)}")
        raise HTTPException(status_code=500, detail=f"Processing failed: {str(e)}")

@app.post("/embeddings")
async def get_embeddings(req: EmbedRequest, authorization: str = Header(None)):
    """Get embeddings for a list of texts."""
    user_id = verify_auth(authorization)
    
    if not check_rate_limit(user_id):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    
    if not req.texts or len(req.texts) == 0:
        raise HTTPException(status_code=400, detail="No texts provided")
    
    try:
        logger.info(f"[embeddings] user={user_id} count={len(req.texts)}")

        # Prefer API key passed in the request; otherwise use the runtime env var.
        # Trim whitespace to avoid false negatives from accidental spaces.
        passed_key = getattr(req, "api_key", None)
        client_key = (passed_key or os.getenv("OPENAI_API_KEY", "")).strip()
        # Build client using the passed key if present, otherwise let get_openai_client
        # fall back to using the environment key.
        client = get_openai_client(passed_key or None)

        # If OPENAI key is missing or it's a known test key, return deterministic mock embeddings
        if not client_key or client_key.startswith("sk-test") or client_key.startswith("sk-proj-test"):
            import hashlib, random
            logger.info("[embeddings] Using MOCK embeddings because OPENAI API key not set or is test key")
            embeddings = []
            DIM = 1536
            for t in req.texts:
                # Deterministic seed from text
                h = hashlib.sha256(t.encode('utf-8')).hexdigest()
                seed = int(h[:16], 16)
                rnd = random.Random(seed)
                vec = [rnd.uniform(-1.0, 1.0) for _ in range(DIM)]
                # Normalize to unit vector
                norm = sum(x * x for x in vec) ** 0.5 or 1.0
                vec = [float(x / norm) for x in vec]
                embeddings.append(vec)
        else:
            response = client.embeddings.create(
                model=req.model,
                input=req.texts,
                timeout=30,
            )
            embeddings = [item.embedding for item in response.data]
        logger.info(f"[embeddings] success user={user_id} count={len(embeddings)}")
        
        return {
            "success": True,
            "embeddings": embeddings,
            "model": req.model,
            "count": len(embeddings)
        }
    except Exception as e:
        logger.exception(f"[embeddings] error user={user_id} {str(e)}")
        raise HTTPException(status_code=500, detail=f"Embedding failed: {str(e)}")

@app.post("/rag/answer")
async def rag_answer(req: BatchRAGRequest, authorization: str = Header(None)):
    """RAG: Answer a question using provided chunks."""
    user_id = verify_auth(authorization)
    
    if not check_rate_limit(user_id):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    # Use API key from request if provided; otherwise fall back to runtime env var.
    passed_key = req.api_key if getattr(req, "api_key", None) else None
    client_key = (passed_key or os.getenv("OPENAI_API_KEY", "")).strip()
    client = get_openai_client(passed_key or None)

    # If no key available, return a deterministic MOCK response for testing
    if not client_key:
        print(f'[RAG_ANSWER] ⚠️  No API key provided, using MOCK response for testing')
        mock_answer = (
            f"Based on the provided excerpts about {req.chunks[0].get('book', 'the book') if req.chunks else 'medical guidelines'}, "
            "here is relevant information: The provided medical guidelines contain important information. "
            "This is a mock response because no valid API key is available. Please provide a real OpenAI API key in your app Settings or set OPENAI_API_KEY environment variable."
        )
        return {
            "success": True,
            "answer": mock_answer,
            "citations": [{"text": chunk.get("text", "")[:200], "book": chunk.get("book", "Unknown")} for chunk in req.chunks[:3]],
            "confidence": 0.5,
        }
    
    try:
        total_chunk_chars = 0
        for chunk in req.chunks:
            text = chunk.get("text", "")
            total_chunk_chars += len(text) if text else 0
        
        # ✅ LOG CHUNKS RECEIVED FROM FRONTEND
        print(f'[RAG_ANSWER] 📥 RECEIVED FROM FRONTEND:')
        print(f'  Question: "{req.question}"')
        print(f'  Chunk count: {len(req.chunks)}')
        print(f'  Total chars: {total_chunk_chars}')
        for i, chunk in enumerate(req.chunks):
            book = chunk.get("book", "Unknown")
            start_page = chunk.get("start_page", "?")
            text = chunk.get("text", "")
            preview = text[:100] + '...' if len(text) > 100 else text
            print(f'  📦 Chunk[{i}] book="{book}" page={start_page} len={len(text)} preview="{preview}"')
        logger.info(f"[rag_answer] user={user_id} question_len={len(req.question)} chunks={len(req.chunks)} chars={total_chunk_chars}")
        
        client = get_openai_client(passed_key or None)
        
        # Build prompt
        # Build prompt
        system_prompt = req.system_prompt or (
            "You are a helpful medical assistant. Your task is to ALWAYS provide a comprehensive answer based on the provided excerpts. "
            "NEVER say 'I cannot find', 'I don't have access to', 'information is not available', or 'I cannot provide'. "
            "Instead, ALWAYS synthesize and use what IS available in the excerpts to answer the question comprehensively. "
            "If excerpts are provided, you MUST draw from them. Provide detailed, thorough answers (3-8 sentences or more). "
            "Include key medical points, recommendations, treatments, or relevant information from the excerpts. "
            "Even if excerpts don't perfectly match, use related medical information to provide helpful context. "
            "ALWAYS respond with an answer — never refuse or say information is unavailable."
        )
        
        # Format chunks
        excerpt_text = "Excerpts:\n\n"
        if req.chunks and len(req.chunks) > 0:
            for i, chunk in enumerate(req.chunks):
                book = chunk.get("book", "Unknown")
                start_page = chunk.get("start_page", "?")
                end_page = chunk.get("end_page", start_page)
                text = chunk.get("text", "")
                if text:
                    excerpt_text += f"[{i+1}] Book: {book} Pages: {start_page}-{end_page}\n{text}\n\n---\n\n"
        else:
            excerpt_text = "[NO_EXCERPTS] Provide a general helpful answer using medical knowledge."
        
        user_message = f"{excerpt_text}\n\nQuestion: {req.question}\n\nProvide a helpful, detailed answer. Return a JSON object with 'answer' (string), 'citations' (array), 'confidence' (0-1 float)."
        
        # ✅ LOG WHAT'S BEING SENT TO OPENAI
        print(f'[RAG_ANSWER] 📤 SENDING TO OPENAI:')
        print(f'  Model: {req.model}')
        print(f'  Max tokens: {req.max_tokens}')
        print(f'  System prompt length: {len(system_prompt)} chars')
        response = client.chat.completions.create(
            model=req.model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message}
            ],
            temperature=req.temperature,
            max_tokens=req.max_tokens,
            timeout=30,
        )

        # Extract answer text robustly from the response object
        answer_text = ""
        if hasattr(response, "choices") and len(response.choices) > 0:
            choice0 = response.choices[0]
            msg = getattr(choice0, "message", None)
            if isinstance(msg, dict):
                answer_text = msg.get("content", "")
            else:
                answer_text = getattr(msg, "content", "") or str(choice0)
        else:
            # Fallback to stringifying the response
            answer_text = str(response)
        
        # ✅ LOG OPENAI RESPONSE (non-sensitive): log length and small preview only
        print(f'[RAG_ANSWER] ✅ RESPONSE FROM OPENAI: answer_len={len(answer_text)}')
        preview_text = answer_text[:200].replace("\n", " ")
        print(f'  Answer preview (first 200 chars): {preview_text}...')
        
        # Try to parse JSON response
        parsed = {"answer": answer_text, "citations": [], "confidence": 0.5}
        try:
            start_idx = answer_text.find("{")
            end_idx = answer_text.rfind("}")
            if start_idx >= 0 and end_idx > start_idx:
                json_str = answer_text[start_idx:end_idx+1]
                parsed = json.loads(json_str)
        except:
            pass
        
        # Verify answer is not a generic "I don't know" response and log accordingly
        answer_lower = (parsed.get("answer", "") or "").lower()
        if any(phrase in answer_lower for phrase in ["don't have access", "cannot provide", "no relevant", "unable to answer", "not available"]):
            logger.warning(f"[rag_answer] Generic/refusal response detected; user={user_id} chunks={len(req.chunks)}")
        
        logger.info(f"[rag_answer] success user={user_id} answer_len={len(answer_text)}")
        
        return {
            "success": True,
            "answer": parsed.get("answer", answer_text),
            "citations": parsed.get("citations", []),
            "confidence": parsed.get("confidence", 0.5),
            "model": req.model,
            "usage": getattr(response, "usage", {})
        }
    except Exception as e:
        logger.exception(f"[rag_answer] error user={user_id} {str(e)}")
        raise HTTPException(status_code=500, detail=f"RAG failed: {str(e)}")

@app.post("/train/book")
async def train_book(req: TrainBookRequest, authorization: str = Header(None)):
    """Train a book by generating Q/A pairs in batches."""
    user_id = verify_auth(authorization)
    
    if not check_rate_limit(user_id):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    
    if not req.book_id or not req.chunks:
        raise HTTPException(status_code=400, detail="book_id and chunks required")
    
    try:
        logger.info(f"[train_book] user={user_id} book={req.book_id} chunks={len(req.chunks)}")
        
        # Batch chunks (~20KB per batch)
        batches = []
        current_batch = []
        batch_size = 0
        max_batch_size = 20 * 1024
        
        for chunk in req.chunks:
            chunk_text = chunk.get("text", "")
            if batch_size + len(chunk_text) > max_batch_size and current_batch:
                batches.append(current_batch)
                current_batch = []
                batch_size = 0
            current_batch.append(chunk)
            batch_size += len(chunk_text) + 200
        
        if current_batch:
            batches.append(current_batch)
        
        logger.info(f"[train_book] split into {len(batches)} batches")
        
        qa_pairs = []
        for batch_idx, batch in enumerate(batches):
            # Build excerpt text
            excerpt_text = "Excerpts:\n\n"
            for chunk in batch:
                book = chunk.get("book", "Unknown")
                start_page = chunk.get("start_page", "?")
                end_page = chunk.get("end_page", start_page)
                text = chunk.get("text", "")
                excerpt_text += f"Book: {book} Pages: {start_page}-{end_page}\n{text}\n\n---\n\n"
            try:
                client = get_openai_client(getattr(req, "api_key", None))
                response = client.chat.completions.create(
                    model=req.model,
                    messages=[
                        {"role": "system", "content": "You are a medical Q&A generator. Extract factual Q&A pairs from the provided text."},
                        {"role": "user", "content": excerpt_text + "\n\nGenerate Q&A pairs as JSON array: [{\"question\": \"...\", \"answer\": \"...\"}, ...]"}
                    ],
                    temperature=req.temperature,
                    max_tokens=req.max_tokens,
                    timeout=30,
                )

                # Extract content robustly
                content = ""
                if hasattr(response, "choices") and len(response.choices) > 0:
                    c0 = response.choices[0]
                    msg = getattr(c0, "message", None)
                    if isinstance(msg, dict):
                        content = msg.get("content", "")
                    else:
                        content = getattr(msg, "content", "") or str(c0)
                else:
                    content = str(response)
                
                # Parse JSON
                try:
                    start_idx = content.find("[")
                    end_idx = content.rfind("]")
                    if start_idx >= 0 and end_idx > start_idx:
                        json_str = content[start_idx:end_idx+1]
                        batch_pairs = json.loads(json_str)
                        qa_pairs.extend(batch_pairs)
                        logger.info(f"[train_book] batch {batch_idx} extracted {len(batch_pairs)} pairs")
                except:
                    logger.warning(f"[train_book] batch {batch_idx} failed to parse JSON")
            except Exception as e:
                logger.exception(f"[train_book] batch {batch_idx} error: {str(e)}")
        
        logger.info(f"[train_book] success user={user_id} total_pairs={len(qa_pairs)}")
        
        return {
            "success": True,
            "book_id": req.book_id,
            "qa_pairs": qa_pairs,
            "count": len(qa_pairs),
            "batches": len(batches)
        }
    except Exception as e:
        logger.exception(f"[train_book] error user={user_id} {str(e)}")
        raise HTTPException(status_code=500, detail=f"Training failed: {str(e)}")

@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """Custom error response handler."""
    return JSONResponse(
        status_code=exc.status_code,
        content={"success": False, "error": exc.detail}
    )


@app.get("/internal/openai_key_status")
async def openai_key_status(authorization: str = Header(None)):
    """Internal endpoint to check whether OPENAI_API_KEY is set on the server.
    Returns a boolean `has_key` but never returns the key itself. Protected by
    the same Authorization header check used elsewhere.
    """
    # Reuse the same simple auth check
    verify_auth(authorization)
    key = os.getenv("OPENAI_API_KEY", "")
    return {"success": True, "has_key": bool(key)}

if __name__ == "__main__":
    import uvicorn
    # Log presence of API key at startup (not the value, for security)
    key_present = bool(os.getenv("OPENAI_API_KEY", "").strip())
    logger.info("=" * 60)
    logger.info("STARTUP: OPENAI_API_KEY present in environment: %s", key_present)
    logger.info("=" * 60)
    # Use the port provided by the hosting environment (Render sets $PORT)
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port)
