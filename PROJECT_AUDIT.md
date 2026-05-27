# Paperless-NGX — Full Project Audit

> Status: snapshot at `pyproject.toml` version **2.20.15** (forked as `bandalore-paperless-ngx`).
> This document is intended as a single-file onboarding bible: read it top-to-bottom and you will know where every piece lives, how it talks to its neighbours, and which patterns the maintainers have settled on. It is also the foundation for the **`FEATURE_PLAN.md`** that lives next to it.

---

## 1. Bird's-Eye View

Paperless-NGX is a **document management system (DMS)** built as a classic two-tier app:

| Tier        | Tech                                                                                    | Where                  |
| ----------- | --------------------------------------------------------------------------------------- | ---------------------- |
| Backend     | Python 3.11+, Django 5.2, DRF 3.16, Celery 5.6 (Redis broker), Channels 4 (WebSockets)  | `src/`                 |
| Frontend    | Angular 21 (NgModule-based, RxJS, Bootstrap 5, ng-bootstrap, ng-select, pdfjs)          | `src-ui/`              |
| Search      | Tantivy (`tantivy~=0.26`) for FTS, FAISS + LLaMA Index for vector search                | `documents/search/`, `paperless_ai/` |
| OCR / Parse | ocrmypdf + Tesseract, Tika, Gotenberg, Azure AI Document Intelligence, custom remote    | `paperless/parsers/`   |
| Storage     | PostgreSQL / MariaDB / SQLite (Django ORM, django-soft-delete, django-treenode)         | `documents/models.py`  |
| Cache/queue | Redis (broker + django cache + channel layer)                                           | `paperless/celery.py`  |
| Auth        | django-allauth (incl. MFA + social), django-guardian (object permissions), DRF tokens   | `paperless/auth.py`    |
| Packaging   | `uv` for Python, `pnpm` for Node, single Dockerfile, s6-overlay rootfs in `docker/`     | root                   |

The runtime is **3 cooperating processes** (plus Redis and optional Gotenberg/Tika):

```
┌──────────────────────────┐    ┌───────────────────────┐    ┌────────────────────────────┐
│  granian/uvloop ASGI     │    │  document_consumer    │    │  celery worker(s) + beat    │
│  manage.py runserver     │    │  (filesystem watcher) │    │  shared_task queue           │
│  Django + DRF + Channels │◄──►│  watchfiles → enqueue │───►│  consume_file, OCR, indexer  │
└──────────┬───────────────┘    └───────────┬───────────┘    └─────────────┬───────────────┘
           │                                │                              │
           ▼                                ▼                              ▼
       ┌────────┐   websocket (ws/status/)  ┌────────────────────────────────────┐
       │ Redis  │◄──────────────────────────│ FS: originals/, archive/, thumbs/, │
       │ (broker│                           │ index/ (Tantivy), llm_index/(FAISS)│
       │ +cache)│                           │ scratch/, consume/                  │
       └────────┘                           └────────────────────────────────────┘
```

---

## 2. Repository Layout (and what to look at first)

```
bandalore-paperless-ngx/
├── AGENTS.md                  # short agent guide (read first)
├── pyproject.toml             # python deps, ruff, mypy, pytest config
├── Dockerfile                 # production image (s6-overlay)
├── docker/                    # compose files + container entrypoints
├── docs/                      # user-facing docs (mkdocs/zensical)
├── scripts/                   # systemd unit files + helpers
├── src/                       # ⇦ all backend code
│   ├── manage.py
│   ├── paperless/             # Django project (settings, urls, asgi, celery, auth)
│   │   ├── settings/          # split settings module
│   │   ├── parsers/           # NEW parser plugin architecture (Protocol + registry)
│   │   │   ├── __init__.py    # ParserProtocol, ParserContext, MetadataEntry
│   │   │   ├── registry.py    # ParserRegistry (singleton + entrypoint discovery)
│   │   │   ├── tesseract.py   # OCR via ocrmypdf
│   │   │   ├── tika.py        # office docs via Tika/Gotenberg
│   │   │   ├── text.py        # plain text
│   │   │   ├── mail.py        # .eml
│   │   │   └── remote.py      # Azure AI Document Intelligence
│   │   ├── config.py          # OcrConfig, AIConfig (DB-backed runtime config)
│   │   ├── consumers.py       # Channels WebSocket consumer (StatusConsumer)
│   │   ├── celery.py          # celery app + signed-pickle, schedules
│   │   └── urls.py            # full URL map (api/, allauth, frontend catch-all)
│   ├── documents/             # core domain
│   │   ├── models.py          # Document, Tag, Correspondent, DocumentType,
│   │   │                      # StoragePath, CustomField, CustomFieldInstance,
│   │   │                      # Note, ShareLink(Bundle), SavedView, UiSettings,
│   │   │                      # PaperlessTask, Workflow*, WorkflowAction*
│   │   ├── serialisers.py     # DRF serialisers (very large)
│   │   ├── views.py           # 20+ ViewSets + custom action endpoints (>5k lines)
│   │   ├── filters.py         # custom filter backends incl. CustomFieldQueryParser
│   │   ├── permissions.py     # guardian helpers + owner-aware querysets
│   │   ├── consumer.py        # ConsumeTaskPlugin orchestration + ConsumerPlugin
│   │   ├── tasks.py           # @shared_task definitions (consume_file, etc.)
│   │   ├── classifier.py      # scikit-learn auto-classifier (Tag/DT/Corresp/SP)
│   │   ├── matching.py        # literal/regex/fuzzy/all/any matching logic
│   │   ├── barcodes.py        # ASN + page-split barcode plugin
│   │   ├── double_sided.py    # collate scanner front/back plugin
│   │   ├── file_handling.py   # storage path templating + atomic moves
│   │   ├── data_models.py     # ConsumableDocument, DocumentMetadataOverrides…
│   │   ├── plugins/
│   │   │   ├── base.py        # ConsumeTaskPlugin ABC + mixins
│   │   │   ├── helpers.py     # ProgressManager (websocket bridge)
│   │   │   └── date_parsing/  # extensible date-parser plugins (entrypoint group)
│   │   ├── workflows/         # workflow runner (assignment/email/webhook/etc.)
│   │   ├── search/            # Tantivy backend (_backend.py, _query.py, _schema.py)
│   │   ├── signals/handlers.py# celery + django signal handlers
│   │   ├── templating/        # Jinja2 templating for filenames/workflow strings
│   │   ├── management/        # `document_consumer`, `document_exporter`, …
│   │   └── tests/             # pytest suite (markers in pyproject)
│   ├── paperless_ai/          # LLM, embeddings, RAG, chat
│   │   ├── client.py          # AIClient (Ollama / OpenAI-like via llama-index)
│   │   ├── ai_classifier.py   # RAG-based tag/correspondent/type suggestions
│   │   ├── embedding.py       # HuggingFace OR OpenAI-like embeddings
│   │   ├── indexing.py        # FAISS vector store via llama-index
│   │   ├── chat.py            # streaming chat-with-documents
│   │   ├── matching.py        # fuzzy fallback (difflib) for AI-suggested names
│   │   └── base_model.py      # DocumentClassifierSchema (pydantic tool-calling)
│   └── paperless_mail/        # IMAP + OAuth (Gmail/Outlook) → document consumer
│       ├── mail.py            # MailAccountHandler / Rule processing
│       ├── oauth.py           # PaperlessMailOAuth2Manager
│       ├── preprocessor.py    # MailMessageDecryptor + base preprocessor
│       └── tasks.py           # @shared_task mail polling
└── src-ui/                    # Angular 21 SPA
    ├── angular.json
    ├── package.json           # pnpm; pdfjs-dist, ng-bootstrap, ng-select…
    └── src/app/
        ├── app-routing.module.ts
        ├── components/        # dashboard, document-list, document-detail,
        │                      # admin/(config,settings,tasks,trash,logs,users-groups),
        │                      # manage/(workflows, mail, saved-views, document-attributes),
        │                      # chat/, file-drop/, document-notes/, …
        ├── services/
        │   ├── rest/          # typed HttpClient services per resource
        │   ├── chat.service.ts
        │   ├── upload-documents.service.ts
        │   ├── tasks.service.ts
        │   ├── websocket-status.service.ts
        │   ├── permissions.service.ts
        │   └── …
        ├── data/              # TypeScript interfaces mirroring backend models
        ├── interceptors/      # CSRF, error handling, version header
        ├── guards/            # PermissionsGuard, DirtyDocGuard, DirtyFormGuard
        ├── pipes/, directives/, utils/
        └── e2e/               # Playwright suite (in src-ui root)
```

---

## 3. Architectural Patterns & Paradigms

### 3.1 Backend

* **Django apps as logical modules**: `documents`, `paperless`, `paperless_ai`, `paperless_mail`. Adding a new feature usually means either extending `documents` or creating a new app (`paperless_X`) — never sprinkling files at the project root.
* **DRF `ModelViewSet` is the default**, augmented by mixins (`PassUserMixin`, `PermissionsAwareDocumentCountMixin`, `BulkPermissionMixin`, `DocumentOperationPermissionMixin`). Custom one-off endpoints are `GenericAPIView` subclasses registered manually in `paperless/urls.py`.
* **OpenAPI everywhere**: every public action carries a `@extend_schema(...)` from drf-spectacular. Schema is exposed at `/api/schema/view/` (Swagger). Adding endpoints without `@extend_schema` is considered a regression.
* **API versioning** via DRF's `URLPathVersioning`/`AcceptHeaderVersioning`: `DEFAULT_VERSION=10`, `ALLOWED_VERSIONS=["9","10"]`. Breaking changes ⇒ new version, old kept until next major.
* **Soft-delete** via `django-soft-delete` on `Document`, `Note`, `CustomFieldInstance`, `ShareLink`. Trash + restore + auto-purge after `EMPTY_TRASH_DELAY`.
* **Object-level permissions** via django-guardian: every "owned" model goes through `ModelWithOwner` (abstract base) + `documents.permissions.get_objects_for_user_owner_aware` helper. Frontend mirror is in `services/permissions.service.ts`.
* **Audit log** via django-auditlog — registered conditionally with `if settings.AUDIT_LOG_ENABLED:` at the bottom of `models.py` for `Document`, `Tag`, `Correspondent`, `DocumentType`, `Note`, `CustomField`, `CustomFieldInstance`.
* **Settings**: 12-factor (`paperless/settings/__init__.py`) reads env vars with `get_*_from_env` helpers. Runtime-mutable settings live in the DB via `paperless.models.ApplicationConfiguration` + dataclass wrappers (`OcrConfig`, `AIConfig`). New runtime knobs go through `ApplicationConfiguration` not env-only.
* **Strict tooling**: `ruff` (88 cols, extensive rule set, `force-single-line` imports), `mypy --strict`, `pyrefly` baseline, `codespell`, prek pre-commit hooks. Tests via `pytest` with markers (`live`, `api`, `search`, `gotenberg`, `tika`, `greenmail`, `nginx`, `management`, `date_parsing`).

### 3.2 Celery / task tracking

The maintainers built a custom **task lifecycle model** on top of Celery (`PaperlessTask` in `documents/models.py:664`). Every backend job that the user might want to see goes through it:

1. `before_task_publish` → creates `PaperlessTask` (`status=PENDING`, `trigger_source` from header)
2. `task_prerun` → flips to `STARTED`, fills `date_started`, `wait_time_seconds`
3. `task_postrun` / `task_failure` → `SUCCESS`/`FAILURE`/`REVOKED`, fills `result_data`, `duration_seconds`
4. Frontend lists/polls via `TasksViewSet` (`/api/tasks/`) and a websocket on `/ws/status/`.

**Rule**: never call `.delay()` without setting `headers={"trigger_source": PaperlessTask.TriggerSource.X}` (see `TriggerSource` enum: `SCHEDULED`, `WEB_UI`, `API_UPLOAD`, `FOLDER_CONSUME`, `EMAIL_CONSUME`, `SYSTEM`, `MANUAL`). New task types must be added to `PaperlessTask.TaskType` text-choices.

**Signed pickle** (set in `paperless/celery.py`) is used for serialization so Celery can carry richer python objects (dataclasses like `ConsumableDocument`).

### 3.3 Plugin architectures (there are TWO!)

#### a) Consumption plugins — `documents/plugins/base.py`

`ConsumeTaskPlugin` is an ABC with `able_to_run`, `setup`, `run`, `cleanup`. The orchestrator in `documents/tasks.py:consume_file` runs them in a fixed order:

```python
[ConsumerPreflightPlugin, AsnCheckPlugin, CollatePlugin, BarcodePlugin,
 AsnCheckPlugin, WorkflowTriggerPlugin, ConsumerPlugin]
```

Plugins may mutate `self.metadata` (`DocumentMetadataOverrides`) or raise `StopConsumeTaskError` to early-exit (used by `BarcodePlugin` when it splits one input into several documents → new `consume_file` tasks).

Mixins to compose: `AlwaysRunPluginMixin`, `NoSetupPluginMixin`, `NoCleanupPluginMixin`.

> The plugin list is currently **hard-coded** in `tasks.py`. The AGENTS guide mentions `settings.CONSUMER_PLUGINS_MODULES` but that constant does not exist in the current code — to add a new plugin today you must edit `consume_file`.

#### b) Parser plugins — `paperless/parsers/`

A **structural Protocol** (`ParserProtocol`, runtime-checkable) replaced the old `DocumentParser` ABC. The `ParserRegistry` singleton in `paperless/parsers/registry.py`:

* registers 5 built-ins (`TextDocumentParser`, `RemoteDocumentParser` (Azure DI), `TikaDocumentParser`, `MailDocumentParser`, `RasterisedDocumentParser`),
* and discovers **third-party parsers** via `importlib.metadata.entry_points(group="paperless_ngx.parsers")`.

Each parser declares `supported_mime_types() → {mime: ext}` and `score(mime, filename, path) → int|None`. Highest score wins; external parsers tie-break ahead of built-ins. Required class-level attrs: `name`, `version`, `author`, `url`.

Parsers receive an immutable `ParserContext` via `parser.configure(ctx)` before `parse()`. Output accessors: `get_text`, `get_date`, `get_archive_path`, `get_thumbnail`, `get_page_count`, `extract_metadata` (returns `list[MetadataEntry]` with `namespace/prefix/key/value`).

#### c) Date-parsing sub-plugins — `documents/plugins/date_parsing/`

Another entrypoint group (`paperless_ngx.date_parsers`) extending the date heuristics; default is `RegexDateParserPlugin`.

### 3.4 Workflows (the in-app no-code engine)

Defined in `documents/models.py` (`Workflow`, `WorkflowTrigger`, `WorkflowAction`, `WorkflowActionEmail`, `WorkflowActionWebhook`, `WorkflowRun`):

* **Triggers**: `CONSUMPTION`, `DOCUMENT_ADDED`, `DOCUMENT_UPDATED`, `SCHEDULED`. Match by source, file pattern, mailrule, content (literal/regex/fuzzy/all/any), filter tags/correspondents/types, schedule offset against `added`/`created`/`modified`/custom date field.
* **Actions**: assignment (title, tags, correspondent, type, storage path, owner, permissions, custom fields), removal, email, webhook, password-removal, move-to-trash. Title/email/webhook bodies are **Jinja2** templates with placeholders defined in `documents/templating/`.
* Scheduled triggers are evaluated by the periodic Celery task `check_scheduled_workflows` (see `documents/tasks.py:435`).

### 3.5 Matching algorithms (used by MatchingModel + workflows)

`documents/matching.py` implements `MATCH_NONE / ANY / ALL / LITERAL / REGEX / FUZZY / AUTO`. `MATCH_AUTO` ⇒ scikit-learn classifier (`documents/classifier.py`, trained nightly by `train_classifier` task) for `Tag`, `Correspondent`, `DocumentType`, `StoragePath`.

### 3.6 Search — Tantivy

In `documents/search/`:
* `_schema.py` defines fields (title, content, tags, correspondent, asn, custom_fields, …);
* `_tokenizer.py` defines stemming & language;
* `_query.py` parses user query DSL;
* `_backend.py` exposes `add_or_update / remove / batch_update / search`.

Frontend hits `/api/documents/?query=…` (handled by `UnifiedSearchViewSet`) and `/api/search/autocomplete/`.

### 3.7 Frontend conventions

* **NgModule app** with lazy-free routing in `app-routing.module.ts`. Routes are guarded by `PermissionsGuard`, with `requiredPermission` or `requiredPermissionAny` data attributes; dirty-form guards prevent navigation away from unsaved changes.
* **Service layer**: one `*.service.ts` per resource under `services/rest/`, all extending `AbstractPaperlessService` for paginated CRUD. Hand-rolled HTTP calls outside this pattern are discouraged.
* **State**: lightweight — RxJS subjects in services + per-component signals; no NgRx. Open document tabs handled by `OpenDocumentsService`.
* **Real-time**: `WebsocketStatusService` subscribes to `/ws/status/` and pushes `task_updated` / `documents_deleted` / `document_updated` events.
* **Typed models**: `src-ui/src/app/data/*.ts` mirror the DRF serialiser shapes (e.g. `document.ts`, `custom-field.ts`, `paperless-task.ts`, `workflow.ts`).
* **PDF rendering**: `pdfjs-dist` inside `document-detail`. `utif` for TIFF previews. `pdfjs` workers are configured in `extra-webpack.config.ts`.
* **Bootstrap 5 + ng-bootstrap** components; icons via `ngx-bootstrap-icons`; selects via `@ng-select/ng-select`.
* **i18n**: Angular i18n with `messages.xlf` + per-locale builds in `angular.json`; backend uses Django `.po` files in `src/locale/`. Both managed via Crowdin.

---

## 4. Data Model Summary

The "central" object is `Document` (`src/documents/models.py:157`). It owns one physical file at `settings.ORIGINALS_DIR/<filename>` and optionally an `archive_filename` (searchable PDF/A) at `settings.ARCHIVE_DIR`. Versioning is via self-FK `root_document` + `version_index`/`version_label`.

| Model | Purpose | Notes |
| ----- | ------- | ----- |
| `Document` | The file + metadata | `content` text, `mime_type`, `created`, `added`, `modified`, `archive_serial_number` (ASN, the physical archive index), soft-delete |
| `Correspondent`, `DocumentType`, `StoragePath`, `Tag` | Faceted metadata | inherit `MatchingModel`; `Tag` is a `TreeNodeModel` (hierarchy). `StoragePath` carries a Jinja2 template that drives the on-disk path |
| `Note` | User-attached note on a document | soft-delete |
| `CustomField` + `CustomFieldInstance` | Schema-less per-doc fields | Data types: `string, url, date, boolean, integer, float, monetary, documentlink, select, longtext`. Monetary uses `value_monetary` ("EUR12.34") with a `GeneratedField` `value_monetary_amount` (Decimal) — already usable for receipts/invoices! |
| `SavedView` (+ `SavedViewFilterRule`) | Persisted searches/dashboards | |
| `ShareLink`, `ShareLinkBundle` | Time-limited public links / zip bundles | bundle build is a celery task |
| `PaperlessTask` | Background job status (see §3.2) | |
| `Workflow`, `WorkflowTrigger`, `WorkflowAction`, `WorkflowActionEmail`, `WorkflowActionWebhook`, `WorkflowRun` | Automation engine | |
| `UiSettings` | per-user UI prefs | |
| `MailAccount`, `MailRule`, `ProcessedMail` (in `paperless_mail`) | IMAP + OAuth account + ruleset + dedup ledger | |
| `ApplicationConfiguration` (in `paperless`) | DB-backed runtime config (OCR + AI knobs) | singleton wrapped by `OcrConfig`, `AIConfig` dataclasses |

---

## 5. Document Lifecycle (end-to-end)

1. **Ingest source** picks a file:
   * **Web UI / API**: `PostDocumentView` (`/api/documents/post_document/`) → enqueues `consume_file.delay(ConsumableDocument(...), DocumentMetadataOverrides(...))`.
   * **Filesystem watcher**: `documents/management/commands/document_consumer.py` uses `watchfiles` on `CONSUMPTION_DIR` and does the same.
   * **Email**: `paperless_mail.tasks.process_mail_accounts` (periodic) → `MailAccountHandler.handle_mail_account` → per `MailRule` enqueues `consume_file` for each attachment / .eml.
2. **`consume_file` task** loops the **plugin list** in §3.3a. Each plugin runs `setup → run → cleanup` while reporting progress to `ProgressManager` (which broadcasts via the channel layer to the `StatusConsumer` websocket).
3. **`ConsumerPlugin.run`** (the heavy one) does:
   * MIME detection (`python-magic`),
   * Parser selection via `get_parser_registry().get_parser_for_file(...)`,
   * `parser.configure(ParserContext)` then `parser.parse(path, mime, produce_archive=...)`,
   * text extraction, archive PDF/A generation (PDF rendition or OCRmyPDF), thumbnail (`get_thumbnail`),
   * classifier-assisted suggestions for `Correspondent`/`Tag`/`DocumentType`/`StoragePath`,
   * filename templating (`file_handling.generate_unique_filename`) and atomic move into `ORIGINALS_DIR`,
   * DB persistence, content indexing into Tantivy, optional LLM index update (`llm_index_add_or_update_document`).
4. **Signals** fire — `document_consumption_finished`, `document_updated` — handlers in `documents/signals/handlers.py` run `WorkflowTrigger.WorkflowTriggerType.DOCUMENT_ADDED` workflows and push websocket updates.
5. **Periodic jobs** (Celery beat): `train_classifier`, `sanity_check`, `check_scheduled_workflows`, `empty_trash`, `cleanup_expired_share_link_bundles`, `process_mail_accounts`, `llmindex_index` (if enabled).

---

## 6. AI / ML Tooling Currently Implemented

These are the AI-adjacent capabilities **already in the codebase** (no new code required):

| Capability | Location | Library | Notes |
| ---------- | -------- | ------- | ----- |
| **OCR** for raster docs (PDF / JPG / PNG / TIFF / GIF / BMP / WEBP / HEIC) | `paperless/parsers/tesseract.py` | `ocrmypdf` (wraps Tesseract + Ghostscript + qpdf) | Produces PDF/A archive. Multi-language (`OCR_LANGUAGE`), modes `skip/redo/force`, deskew/rotate via `OcrConfig` |
| **Office/PDF → PDF/A**, text extraction | `paperless/parsers/tika.py` | `gotenberg-client` + `tika-client` | Calls remote Gotenberg + Tika services |
| **Plain-text parser** | `paperless/parsers/text.py` | stdlib | |
| **E-mail (.eml) parser** | `paperless/parsers/mail.py` | mailparser + custom HTML→PDF via Gotenberg | Layout configurable per mail rule (`PdfLayout`) |
| **Remote OCR** | `paperless/parsers/remote.py` | `azure-ai-documentintelligence` ≥1.0.2 | Optional commercial fallback |
| **Barcode / ASN / page-split** | `documents/barcodes.py` | `zxing-cpp`, `pdf2image` | Splits multi-doc scans by barcode separator pages |
| **Double-sided collation** | `documents/double_sided.py` | — | For odd/even page scanners |
| **Date extraction from content/filename** | `documents/plugins/date_parsing/` | `dateparser`, `regex`, `python-dateutil` | Extensible via entrypoints |
| **Language detection** | `documents/plugins/date_parsing/`, parsers | `langdetect`, `nltk` | |
| **Auto-classifier** for Tag/Type/Correspondent/StoragePath | `documents/classifier.py` | `scikit-learn` (TF-IDF + classifier) | Trained nightly; only when `MATCH_AUTO` items exist |
| **Fuzzy matching** | `documents/matching.py` | `rapidfuzz` | Used by `MATCH_FUZZY` and by AI-suggested name reconciliation (`paperless_ai/matching.py` uses `difflib` for cheap fallback) |
| **LLM document classification (RAG)** | `paperless_ai/ai_classifier.py` | `llama-index-core` + `llama-index-llms-ollama` / `openai-like` | Tool-calling via pydantic `DocumentClassifierSchema`; returns `{title, tags, correspondents, document_types, storage_paths, dates}` |
| **Embedding / vector index** | `paperless_ai/embedding.py`, `paperless_ai/indexing.py` | `sentence-transformers` (HF) or `OpenAILikeEmbedding`; `faiss-cpu`; `llama-index-vector-stores-faiss` | Persisted at `LLM_INDEX_DIR`, append-only FAISS IndexFlatL2, docstore-based update/replace, similarity retrieval |
| **Chat-with-documents (RAG, streaming)** | `paperless_ai/chat.py`, `ChatStreamingView` (`/api/documents/chat/`) | llama-index `RetrieverQueryEngine` + Ollama/OpenAI-like | UI in `src-ui/src/app/components/chat/` + `services/chat.service.ts`. Streams chunks + a JSON metadata trailer with document references |
| **Full-text search** | `documents/search/` | `tantivy` (Rust) | Custom DSL parser, stemmers per language |
| **Workflow Jinja2 templating** | `documents/templating/` | `jinja2` | Title/email/webhook templates |
| **Webhooks (workflow action)** | `documents/workflows/webhooks.py` | `httpx` (via `paperless.network.validate_outbound_http_url`) | SSRF-validated |
| **Per-document permissions** | guardian | `django-guardian` | |
| **Pickled task payloads, signed** | `paperless/celery.py` | celery | |

**AI integrations are configured via `AIConfig`** (DB-backed): `llm_backend` (`ollama` | `openai-like`), `llm_model`, `llm_endpoint`, `llm_api_key`, `llm_embedding_backend` (`huggingface` | `openai-like`), `llm_embedding_model`, `llm_index_enabled`, `llm_allow_internal_endpoints`. Outbound URLs go through `paperless.network.validate_outbound_http_url` for SSRF protection.

---

## 7. Frontend Architecture & Conventions

### 7.1 Module skeleton

Single `AppModule` + `AppRoutingModule`; child routes live under `AppFrameComponent` (sidebar + topbar). Components are **standalone-style only where needed** — most are declared in NgModules. Forms use Angular's typed reactive forms; dirty checking via `@ngneat/dirty-check-forms`.

### 7.2 Adding a domain object — recipe

1. Add a TS interface in `src-ui/src/app/data/` (e.g. `receipt.ts`).
2. Add a service in `src-ui/src/app/services/rest/` extending `AbstractPaperlessService` or `AbstractNameFilterService`.
3. Add a route in `app-routing.module.ts` with a `PermissionsGuard` config (and a `requiredPermission` referencing `PermissionAction` + `PermissionType` enums in `services/permissions.service.ts`).
4. Add the navigation entry in `components/app-frame/app-frame.component.html`.
5. Add components in `components/manage/<thing>/` (list + edit dialog pattern, see `components/manage/mail/` and `components/manage/workflows/` for examples).
6. Mirror the new permission type in `PermissionsService` and bump the backend `PermissionType` enum if relevant.

### 7.3 Custom Fields are the cheapest way to add metadata

Because of `CustomField` + `CustomFieldInstance`, you can already store: amount (monetary), date (date), boolean ("paid"), select (enum), longtext (translation), document-link (back-reference). Frontend has a generic edit widget in `document-detail` that picks the right input type. **Whenever possible, prefer adding a `CustomField` over a new column** — it's automatic in the API, in search (`CustomFieldQueryParser`), in workflows, and in the UI.

---

## 8. Configuration & Deployment Surface

* **Compose files**: `docker/compose/docker-compose.{sqlite,postgres,mariadb}{,-tika}.yml` + CI variant. All read `docker/compose/docker-compose.env`.
* **Entrypoint** in `docker/rootfs/` uses s6-overlay to supervise: webserver (granian ASGI), `document_consumer`, celery worker, celery beat, optional `flower`.
* **Volumes**: `data/` (DB, indexes, models), `media/` (`originals/`, `archive/`, `thumbnails/`), `consume/` (watch dir), `export/`.
* **Environment**: > 200 `PAPERLESS_*` variables documented in `docs/configuration.md`. Override anything via `paperless.conf` (read via `python-dotenv`).
* **Pre-commit**: `uv run prek install` installs ruff/codespell/etc.

---

## 9. Testing

* Backend: `pytest` from `src/`, parallel by default (`pytest-xdist`, `--dist=loadscope`). Markers configured strictly. `pytest-env` injects `PAPERLESS_*` test defaults. Coverage report → `htmlcov/`.
* Frontend: `pnpm test` (Jest). E2E: `pnpm exec playwright test` (specs in `src-ui/e2e/`).
* Integration tests under `pytest -m live` require Gotenberg/Tika/Greenmail/nginx — start via `docker/scripts/start_services.sh`.

---

## 10. Cross-Platform & Runtime Reality Check

> **Important** for the planning doc: Paperless-NGX has been *engineered for Linux containers*. The clue is everywhere: `[tool.uv] environments = ["sys_platform == 'darwin'", "sys_platform == 'linux'"]` (no `win32`), `Dockerfile` baked around Debian Trixie, `ocrmypdf` depending on `qpdf`, `ghostscript`, `tesseract`, `unpaper`, `imagemagick`, `pngquant`, `jbig2enc`, `gsfonts`. The author can almost certainly **develop** on Windows via WSL2 or Docker Desktop, but native Windows installation is unsupported; the Python deps that block it are `psycopg-c` (pre-built for linux only), and the binary tools above.
>
> **Consequence for the new feature plan**: anything that needs to live on a *Windows desktop* (capturing system audio, hotkeys, OS-level file dialogs, Outlook OLE) cannot reasonably ship inside the paperless container. We will need a **companion Windows-side helper** that uploads to paperless via REST. That decision is explicit in `FEATURE_PLAN.md`.

The web client itself is pure browser → it runs anywhere Chromium/Firefox runs (Windows, Mac, Linux, iPad). The browser has no access to system audio loopback, no global hotkeys, and limited filesystem access (only `<input type=file>` / drag-drop / File System Access API).

---

## 11. Extension Points Cheat-Sheet

| Want to … | Best lever |
| --------- | ---------- |
| Add a new file format | Implement `ParserProtocol`, register as a Python entrypoint `paperless_ngx.parsers` or call `register_builtin` in a new app's `AppConfig.ready` |
| Add a step to consumption | Subclass `ConsumeTaskPlugin` (+ mixins), append to the list in `documents/tasks.py:consume_file` (no entrypoint discovery yet) |
| Add a metadata field | First try `CustomField` (no code). Otherwise: model field → migration → serialiser → frontend interface |
| Trigger something when a doc is added | Workflow (`DOCUMENT_ADDED` trigger) — or a Django signal handler in `documents/signals/handlers.py` |
| Add an LLM use-case | Use `paperless_ai.client.AIClient` (Ollama/OpenAI-like) and persist intermediate state in `CustomField`s or a new domain model |
| Add a date heuristic | Implement `DateParserPluginBase`, register entrypoint `paperless_ngx.date_parsers` |
| Add a REST endpoint | Add ViewSet (DRF) + `@extend_schema` + register in `paperless/urls.py` |
| Add a periodic job | `@shared_task`, schedule via `paperless/celery.py` beat config, emit `PaperlessTask` |
| Add a websocket event | Extend `paperless/consumers.py:StatusConsumer` and broadcast from celery handler |
| Add a UI section | Route in `app-routing.module.ts` + entry in `app-frame` + component under `components/manage/…` + service under `services/rest/` |

---

## 12. Conventions Quick-Ref

* **Python imports** — single-line, isort-managed by ruff, no relative imports across apps.
* **Line length** 88; PEP 8 with extras: `COM`, `DJ`, `FBT` (boolean trap), `PTH` (pathlib), `SIM`, `UP`, `RUF`, `TC` (type-checking-only imports allowed).
* **Logger names** — `paperless.<area>` (e.g. `paperless.consumer`, `paperless.parsing.tesseract`, `paperless_ai.client`).
* **Models** — every owned model inherits `ModelWithOwner`; audit-log registration goes at the bottom of `models.py` under `if settings.AUDIT_LOG_ENABLED`.
* **Migrations** — auto via `makemigrations`; per-file ignore for E501/SIM/T201 is configured.
* **Tests** — fixtures + factory-boy in `documents/tests/conftest.py`. Mark live tests with the appropriate marker.
* **OpenAPI** — annotate every custom action with `@extend_schema(...)`.
* **i18n** — wrap user-facing strings in `gettext_lazy as _` (backend) or Angular `i18n` tags (frontend).
* **Sec** — outbound URLs (webhooks, LLM endpoints) → `paperless.network.validate_outbound_http_url`.

---

## 13. Known Soft Spots / Foot-guns

1. The consumption plugin list is hard-coded (no settings hook in current code). Adding new ones means a code change to `tasks.py:consume_file`.
2. FAISS `IndexFlatL2` is append-only — updates are simulated by deleting from the `docstore` only; rebuild is required to actually shrink the vector store (`queue_llm_index_update_if_needed(rebuild=True)`).
3. `signed-pickle` Celery serializer means everything in a task payload must be picklable. Dataclasses ok, ORM instances **not**.
4. `Tantivy` is single-threaded for writes — heavy bulk-updates should use the `batch_update()` context manager.
5. `value_monetary` is stored as a 128-char string `"EUR12.34"`; the generated decimal column `value_monetary_amount` only exposes the numeric part — currency must be parsed manually for analytics.
6. `paperless_mail` only **reads** mail (IMAP) — there is no SMTP send-mail integration for arbitrary purposes; outbound mail is restricted to workflow `WorkflowActionEmail`.
7. The "Person" concept does not exist as its own model — `Correspondent` is the closest, but it's just a string name + matching rules.
8. There is no built-in URL/web-page archiver, transcription engine, or receipts-specific schema. These are the gaps the new feature plan needs to fill.

---

*End of audit.*

