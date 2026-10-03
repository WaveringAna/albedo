// Package daemon implements the protocol 3 client. Wire resources follow docs/openapi.yaml.
package daemon

import "encoding/json"

type wireAccount struct {
	ID                 string   `json:"id"`
	Provider           string   `json:"provider"`
	Label              string   `json:"label"`
	Detail             string   `json:"detail"`
	SelectedByProfiles []string `json:"selected_by_profiles"`
}

type wireActionOperation struct {
	OperationID  string                 `json:"operation_id"`
	Method       string                 `json:"method"`
	PathTemplate string                 `json:"path_template"`
	Path         map[string]wireBinding `json:"path"`
	Query        map[string]wireBinding `json:"query"`
	Headers      map[string]wireBinding `json:"headers"`
	Body         map[string]wireBinding `json:"body"`
	ResultSchema json.RawMessage        `json:"result_schema"`
}

type wireActivity struct {
	Lines []struct {
		Kind string `json:"kind"`
		Text string `json:"text"`
	} `json:"lines"`
	OutputScalars   int64  `json:"output_scalars"`
	OutputUTF8Bytes int64  `json:"output_utf8_bytes"`
	ObservedAt      string `json:"observed_at"`
	LatestInput     *struct {
		InputID string `json:"input_id"`
		Source  string `json:"source"`
		Bytes   int64  `json:"bytes"`
	} `json:"latest_input" nullable:"true"`
	LatestAnswer *struct {
		MessageID string `json:"message_id"`
		Bytes     int64  `json:"bytes"`
	} `json:"latest_answer" nullable:"true"`
}

type wireAdmissionProblem struct {
	Type   string `json:"type"`
	Title  string `json:"title"`
	Status int64  `json:"status"`
	Detail string `json:"detail"`
	Code   string `json:"code"`
	Fields []struct {
		Pointer string `json:"pointer"`
		Detail  string `json:"detail"`
	} `json:"fields,omitempty"`
}

type wireAuth struct {
	Providers []wireLoginProvider `json:"providers"`
	Accounts  []wireAccount       `json:"accounts"`
}

type wireBinding = json.RawMessage

type wireCachePolicyEntry struct {
	ID    string `json:"id"`
	Layer string `json:"layer"`
	Match struct {
		Extension []string `json:"extension" nullable:"true"`
		Host      []string `json:"host" nullable:"true"`
		Model     []string `json:"model" nullable:"true"`
	} `json:"match"`
	Policy string `json:"policy"`
	Clock  string `json:"clock"`
	Tiers  []struct {
		Seconds int64    `json:"seconds"`
		Write   *float64 `json:"write" nullable:"true"`
	} `json:"tiers" nullable:"true"`
	Read     *float64 `json:"read" nullable:"true"`
	Survival *struct {
		Typical int64  `json:"typical"`
		Max     *int64 `json:"max" nullable:"true"`
	} `json:"survival" nullable:"true"`
	Evidence string `json:"evidence"`
	Source   string `json:"source"`
	Checked  string `json:"checked"`
	Note     string `json:"note"`
}

type wireCachePolicyLayer struct {
	Name   string          `json:"name"`
	Path   string          `json:"path"`
	Loaded bool            `json:"loaded"`
	Error  *wireSafeReason `json:"error" nullable:"true"`
}

type wireCachePolicyPage struct {
	Entries []wireCachePolicyEntry `json:"entries"`
	Layers  []wireCachePolicyLayer `json:"layers"`
	Matched *wireCachePolicyEntry  `json:"matched" nullable:"true"`
	Next    *string                `json:"next" nullable:"true"`
}

type wireCachePolicyReloadOutcome struct {
	State   string          `json:"state"`
	Failure *wireSafeReason `json:"failure" nullable:"true"`
}

type wireCachePrior struct {
	Provider   string  `json:"provider"`
	Model      *string `json:"model" nullable:"true"`
	TTLSeconds *int64  `json:"ttl_seconds" nullable:"true"`
	Source     string  `json:"source"`
}

type wireCapabilitySettings struct {
	Preferences map[string]bool `json:"preferences"`
}

type wireCatalog struct {
	Discovery *struct {
		Revision    string                 `json:"revision"`
		Workspace   string                 `json:"workspace"`
		Candidates  []wireCatalogCandidate `json:"candidates"`
		Diagnostics []wireSafeReason       `json:"diagnostics"`
		Next        *string                `json:"next" nullable:"true"`
	} `json:"discovery" nullable:"true"`
	DiscoveryFailure *wireSafeReason `json:"discovery_failure" nullable:"true"`
	Loaded           struct {
		Revision *string           `json:"revision" nullable:"true"`
		Commands []json.RawMessage `json:"commands"`
		Next     *string           `json:"next" nullable:"true"`
	} `json:"loaded"`
	Pages []wirePageDescriptor `json:"pages,omitempty"`
}

type wireCatalogCandidate struct {
	ID               string                 `json:"id"`
	Kind             string                 `json:"kind"`
	Title            string                 `json:"title"`
	Description      string                 `json:"description"`
	Source           string                 `json:"source"`
	ResolvedSource   *string                `json:"resolved_source" nullable:"true"`
	PreferenceKey    *string                `json:"preference_key" nullable:"true"`
	Valid            bool                   `json:"valid"`
	Eligible         bool                   `json:"eligible"`
	EffectiveEnabled bool                   `json:"effective_enabled"`
	GlobalPreference *bool                  `json:"global_preference" nullable:"true"`
	SessionOverride  *bool                  `json:"session_override" nullable:"true"`
	ShadowedBy       *string                `json:"shadowed_by" nullable:"true"`
	Dependencies     []string               `json:"dependencies"`
	Quarantined      bool                   `json:"quarantined"`
	Diagnostic       *wireSafeReason        `json:"diagnostic" nullable:"true"`
	Extension        *wireExtensionMetadata `json:"extension" nullable:"true"`
}

type wireCheckpoint struct {
	Position     int64       `json:"position"`
	CheckpointID string      `json:"checkpoint_id"`
	Title        string      `json:"title"`
	TurnType     string      `json:"turn_type"`
	Preview      wirePreview `json:"preview"`
}

type wireCheckpointPage struct {
	Items     []wireCheckpoint `json:"items"`
	Older     *string          `json:"older" nullable:"true"`
	Newer     *string          `json:"newer" nullable:"true"`
	HighWater int64            `json:"high_water"`
}

type wireCollectionBatch = json.RawMessage

type wireCollectionReadyBatch struct {
	Events []json.RawMessage `json:"events"`
}

type wireCompactionObservation struct {
	Strategy       *string `json:"strategy" nullable:"true"`
	BeforeTokens   *int64  `json:"before_tokens" nullable:"true"`
	AfterTokens    *int64  `json:"after_tokens" nullable:"true"`
	EvictedEntries int64   `json:"evicted_entries"`
	Summary        string  `json:"summary"`
}

type wireCompactionResult struct {
	SelectionApplied  bool                       `json:"selection_applied"`
	EffectiveStrategy *string                    `json:"effective_strategy" nullable:"true"`
	State             string                     `json:"state"`
	Observation       *wireCompactionObservation `json:"observation" nullable:"true"`
	Failure           *wireSafeReason            `json:"failure" nullable:"true"`
}

type wireComposition struct {
	DesiredRevision string                     `json:"desired_revision"`
	LoadedRevision  *string                    `json:"loaded_revision" nullable:"true"`
	NeedsReload     bool                       `json:"needs_reload"`
	Dependencies    map[string][]string        `json:"dependencies"`
	Quarantine      []wireQuarantineDiagnostic `json:"quarantine"`
	Availability    map[string]bool            `json:"availability"`
}

type wireContentPart struct {
	Field       string `json:"field"`
	OffsetBytes int64  `json:"offset_bytes"`
	Encoding    string `json:"encoding"`
	Text        string `json:"text"`
	Complete    bool   `json:"complete"`
}

type wireContentReference struct {
	URL   string `json:"url"`
	Field string `json:"field"`
	Bytes int64  `json:"bytes"`
}

type wireContextCompaction struct {
	Status                    string   `json:"status"`
	Strategy                  *string  `json:"strategy" nullable:"true"`
	TriggerFreePercent        *float64 `json:"trigger_free_percent" nullable:"true"`
	InputLimitTokens          *int64   `json:"input_limit_tokens" nullable:"true"`
	EstimatedInputTokens      *int64   `json:"estimated_input_tokens" nullable:"true"`
	ProviderInputTokens       *int64   `json:"provider_input_tokens" nullable:"true"`
	ProviderCachedInputTokens *int64   `json:"provider_cached_input_tokens" nullable:"true"`
	BeforeItems               *int64   `json:"before_items" nullable:"true"`
	AfterItems                *int64   `json:"after_items" nullable:"true"`
	Source                    *string  `json:"source" nullable:"true"`
	EstimateMethod            *string  `json:"estimate_method" nullable:"true"`
}

type wireContextSection struct {
	ID        string      `json:"id"`
	Label     string      `json:"label"`
	Kind      string      `json:"kind"`
	Source    *string     `json:"source" nullable:"true"`
	ItemCount int64       `json:"item_count"`
	UTF8Bytes int64       `json:"utf8_bytes"`
	PageCount int64       `json:"page_count"`
	Preview   wirePreview `json:"preview"`
}

type wireContextSectionPage struct {
	SnapshotID string  `json:"snapshot_id"`
	SectionID  string  `json:"section_id"`
	Text       string  `json:"text"`
	Omitted    *string `json:"omitted" nullable:"true"`
	Page       int64   `json:"page"`
	PageCount  int64   `json:"page_count"`
}

type wireContextSummary struct {
	State               string                `json:"state"`
	SnapshotID          *string               `json:"snapshot_id" nullable:"true"`
	CapturedAt          *string               `json:"captured_at" nullable:"true"`
	Provider            *string               `json:"provider" nullable:"true"`
	Model               *string               `json:"model" nullable:"true"`
	Protocol            *string               `json:"protocol" nullable:"true"`
	ContextWindowTokens *int64                `json:"context_window_tokens" nullable:"true"`
	Compaction          wireContextCompaction `json:"compaction"`
	Sections            []wireContextSection  `json:"sections"`
	Reason              *wireSafeReason       `json:"reason" nullable:"true"`
}

type wireCreation struct {
	Submitted json.RawMessage `json:"submitted"`
	Resolved  struct {
		Workspace       string  `json:"workspace"`
		ProviderProfile *string `json:"provider_profile" nullable:"true"`
		Model           *string `json:"model" nullable:"true"`
		Effort          *string `json:"effort" nullable:"true"`
	} `json:"resolved"`
}

type wireCreationDecision struct {
	Kind       string        `json:"kind"`
	SessionID  string        `json:"session_id"`
	Admission  string        `json:"admission"`
	HTTPStatus int64         `json:"http_status"`
	Creation   *wireCreation `json:"creation" nullable:"true"`
	DecidedAt  *string       `json:"decided_at" nullable:"true"`
	DeletedAt  *string       `json:"deleted_at" nullable:"true"`
}

type wireCursor struct {
	Generation string `json:"generation"`
	Sequence   int64  `json:"sequence"`
}

type wireDelivery struct {
	ID             string          `json:"id"`
	HookID         string          `json:"hook_id"`
	SessionID      string          `json:"session_id"`
	ReceivedAt     string          `json:"received_at"`
	DeliveredAt    *string         `json:"delivered_at" nullable:"true"`
	Attempts       int64           `json:"attempts"`
	DeferralReason *wireSafeReason `json:"deferral_reason" nullable:"true"`
}

type wireDeliveryDetail struct {
	ID             string          `json:"id"`
	HookID         string          `json:"hook_id"`
	SessionID      string          `json:"session_id"`
	ReceivedAt     string          `json:"received_at"`
	DeliveredAt    *string         `json:"delivered_at" nullable:"true"`
	Attempts       int64           `json:"attempts"`
	DeferralReason *wireSafeReason `json:"deferral_reason" nullable:"true"`
	Payload        struct {
		Encoding string `json:"encoding"`
		Data     string `json:"data"`
	} `json:"payload"`
}

type wireDeliveryPage struct {
	Items []wireDelivery `json:"items"`
	Next  *string        `json:"next" nullable:"true"`
}

type wireEntryContentPage struct {
	EntryID string            `json:"entry_id"`
	Parts   []wireContentPart `json:"parts"`
	Next    *string           `json:"next" nullable:"true"`
	Image   *struct {
		MimeType      string `json:"mime_type"`
		Width         int64  `json:"width"`
		Height        int64  `json:"height"`
		OriginalBytes int64  `json:"original_bytes"`
	} `json:"image" nullable:"true"`
}

type wireExtensionDeletion struct {
	ID           string           `json:"id"`
	Notification wireNotification `json:"notification"`
}

type wireExtensionMetadata struct {
	Context       bool     `json:"context"`
	Tools         []string `json:"tools"`
	PythonModules []string `json:"python_modules"`
	Plugins       []string `json:"plugins"`
}

type wireExtensionSettings struct {
	Defaults map[string]bool `json:"defaults"`
}

type wireFormField struct {
	Name           string          `json:"name"`
	Label          string          `json:"label"`
	Type           string          `json:"type"`
	Required       bool            `json:"required"`
	Default        json.RawMessage `json:"default"`
	DefaultBinding struct {
		Source  string `json:"source"`
		Pointer string `json:"pointer"`
	} `json:"default_binding,omitempty"`
	Choices []struct {
		Value json.RawMessage `json:"value"`
		Label string          `json:"label"`
	} `json:"choices"`
	Minimum     *float64 `json:"minimum" nullable:"true"`
	Maximum     *float64 `json:"maximum" nullable:"true"`
	Description string   `json:"description"`
}

type wireGitFacts struct {
	Kind      string  `json:"kind"`
	Branch    *string `json:"branch" nullable:"true"`
	Revision  *string `json:"revision" nullable:"true"`
	Dirty     *bool   `json:"dirty" nullable:"true"`
	Added     *int64  `json:"added" nullable:"true"`
	Modified  *int64  `json:"modified" nullable:"true"`
	Removed   *int64  `json:"removed" nullable:"true"`
	Root      string  `json:"root"`
	Changed   *int64  `json:"changed" nullable:"true"`
	TouchedAt *string `json:"touched_at" nullable:"true"`
}

type wireGlance struct {
	Extension string          `json:"extension"`
	Title     string          `json:"title"`
	Rows      []wirePageRow   `json:"rows"`
	URL       string          `json:"url"`
	Data      json.RawMessage `json:"data,omitempty"`
}

type wireHTTPCommand struct {
	ID                string              `json:"id"`
	SlashName         string              `json:"slash_name"`
	Description       string              `json:"description"`
	Arguments         []wireFormField     `json:"arguments"`
	CallerPermissions []string            `json:"caller_permissions"`
	Delivery          string              `json:"delivery"`
	Operation         wireActionOperation `json:"operation"`
}

type wireHistoryEntry struct {
	ID              string            `json:"id"`
	Position        int64             `json:"position"`
	Kind            string            `json:"kind"`
	TurnID          *string           `json:"turn_id" nullable:"true"`
	InputID         *string           `json:"input_id" nullable:"true"`
	CreatedAt       *string           `json:"created_at" nullable:"true"`
	Content         []json.RawMessage `json:"content"`
	CheckpointID    *string           `json:"checkpoint_id" nullable:"true"`
	ContentComplete bool              `json:"content_complete"`
	Tool            *struct {
		Name           string  `json:"name"`
		ToolCallID     string  `json:"tool_call_id"`
		ProgressCallID *string `json:"progress_call_id" nullable:"true"`
	} `json:"tool" nullable:"true"`
	ThinkingDurationMs *int64 `json:"thinking_duration_ms,omitempty" nullable:"true"`
}

type wireHistoryPage struct {
	Items     []wireHistoryEntry `json:"items"`
	Older     *string            `json:"older" nullable:"true"`
	Newer     *string            `json:"newer" nullable:"true"`
	HighWater int64              `json:"high_water"`
}

type wireHook struct {
	ConfigurationResource wireHookConfigurationResource `json:"configuration_resource"`
	DeliveryURL           string                        `json:"delivery_url"`
	PendingCount          int64                         `json:"pending_count"`
	DeferralReason        *wireSafeReason               `json:"deferral_reason" nullable:"true"`
}

type wireHookChange struct {
	Resource     wireHookConfigurationResource `json:"resource"`
	Notification wireNotification              `json:"notification"`
	Secret       string                        `json:"secret,omitempty"`
}

type wireHookConfiguration struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	SessionID       string `json:"session_id"`
	Enabled         bool   `json:"enabled"`
	SignatureHeader string `json:"signature_header"`
	SignaturePrefix string `json:"signature_prefix"`
	Revision        string `json:"revision"`
}

type wireHookConfigurationResource struct {
	URL   string                `json:"url"`
	ETag  string                `json:"etag"`
	Value wireHookConfiguration `json:"value"`
}

type wireHookPage struct {
	Items []wireHook `json:"items"`
	Next  *string    `json:"next" nullable:"true"`
}

type wireHookPermission struct {
	SessionID   string `json:"session_id"`
	AgentManage bool   `json:"agent_manage"`
	Revision    string `json:"revision"`
}

type wireHookPermissionChange struct {
	Resource     wireHookPermissionResource `json:"resource"`
	Notification wireNotification           `json:"notification"`
}

type wireHookPermissionResource struct {
	URL   string             `json:"url"`
	ETag  string             `json:"etag"`
	Value wireHookPermission `json:"value"`
}

type wireHost struct {
	Target         string          `json:"target"`
	State          string          `json:"state"`
	Detail         *wireSafeReason `json:"detail" nullable:"true"`
	ObservedAt     *string         `json:"observed_at" nullable:"true"`
	Os             *string         `json:"os" nullable:"true"`
	Architecture   *string         `json:"architecture" nullable:"true"`
	Home           *string         `json:"home" nullable:"true"`
	Authentication *struct {
		Instructions string  `json:"instructions"`
		SSHTarget    string  `json:"ssh_target"`
		ControlPath  *string `json:"control_path" nullable:"true"`
	} `json:"authentication" nullable:"true"`
}

type wireHostPage struct {
	Items []wireHost `json:"items"`
	Next  *string    `json:"next" nullable:"true"`
}

type wireImageMetadata struct {
	MimeType      string               `json:"mime_type"`
	Width         int64                `json:"width"`
	Height        int64                `json:"height"`
	OriginalBytes int64                `json:"original_bytes"`
	Reference     wireContentReference `json:"reference"`
}

type wireImageUpload struct {
	MimeType string `json:"mime_type"`
	Data     string `json:"data"`
}

type wireInput struct {
	ID                 string                `json:"id"`
	SessionID          string                `json:"session_id"`
	Kind               string                `json:"kind"`
	Admission          string                `json:"admission"`
	HTTPStatus         int64                 `json:"http_status"`
	Problem            *wireAdmissionProblem `json:"problem" nullable:"true"`
	AcceptedAt         *string               `json:"accepted_at" nullable:"true"`
	AcceptanceOrder    *int64                `json:"acceptance_order" nullable:"true"`
	Delivery           *string               `json:"delivery" nullable:"true"`
	BlockingReason     *wireSafeReason       `json:"blocking_reason" nullable:"true"`
	TranscriptPosition *int64                `json:"transcript_position" nullable:"true"`
	Turn               *wireTurn             `json:"turn" nullable:"true"`
	ClientID           *string               `json:"client_id" nullable:"true"`
}

type wireInputCancellation struct {
	Input  wireInput `json:"input"`
	Result string    `json:"result"`
}

type wireInputCommand struct {
	ID                string          `json:"id"`
	SlashName         string          `json:"slash_name"`
	Description       string          `json:"description"`
	Arguments         []wireFormField `json:"arguments"`
	CallerPermissions []string        `json:"caller_permissions"`
	Delivery          string          `json:"delivery"`
	CommandID         string          `json:"command_id"`
}

type wireInterruption struct {
	RunID             *string      `json:"run_id" nullable:"true"`
	State             string       `json:"state"`
	CancelledInputIDs []string     `json:"cancelled_input_ids"`
	Warnings          wireWarnings `json:"warnings"`
}

type wireJJFacts struct {
	Kind        string  `json:"kind"`
	ChangeID    *string `json:"change_id" nullable:"true"`
	Revision    *string `json:"revision" nullable:"true"`
	Description *string `json:"description" nullable:"true"`
	Dirty       *bool   `json:"dirty" nullable:"true"`
	Conflicts   *bool   `json:"conflicts" nullable:"true"`
	Root        string  `json:"root"`
	Changed     *int64  `json:"changed" nullable:"true"`
	TouchedAt   *string `json:"touched_at" nullable:"true"`
	Bookmark    *struct {
		Name  string `json:"name"`
		Ahead int64  `json:"ahead"`
	} `json:"bookmark" nullable:"true"`
}

type wireKernel struct {
	State            string           `json:"state"`
	Stage            *string          `json:"stage" nullable:"true"`
	Build            *string          `json:"build" nullable:"true"`
	Stale            bool             `json:"stale"`
	StalenessReasons []wireSafeReason `json:"staleness_reasons"`
	LiveJobCount     *int64           `json:"live_job_count" nullable:"true"`
	InstanceID       *string          `json:"instance_id" nullable:"true"`
}

type wireKernelUpgradeResult struct {
	OldBuild    *string `json:"old_build" nullable:"true"`
	NewBuild    *string `json:"new_build" nullable:"true"`
	State       string  `json:"state"`
	StoppedJobs []struct {
		ID     string         `json:"id"`
		Reason wireSafeReason `json:"reason"`
	} `json:"stopped_jobs"`
	Warnings    wireWarnings    `json:"warnings"`
	Failure     *wireSafeReason `json:"failure" nullable:"true"`
	OldKernelID *string         `json:"old_kernel_id" nullable:"true"`
	NewKernelID *string         `json:"new_kernel_id" nullable:"true"`
}

type wireLinkChange struct {
	Resource          wireLinkConfigurationResource `json:"resource"`
	Notifications     []wireTargetNotification      `json:"notifications"`
	NotificationCount int64                         `json:"notification_count"`
	Truncated         bool                          `json:"truncated"`
}

type wireLinkConfiguration struct {
	Workspace string   `json:"workspace"`
	GroupID   string   `json:"group_id"`
	Members   []string `json:"members"`
	Revision  string   `json:"revision"`
	Next      *string  `json:"next" nullable:"true"`
}

type wireLinkConfigurationResource struct {
	URL   string                `json:"url"`
	ETag  string                `json:"etag"`
	Value wireLinkConfiguration `json:"value"`
}

type wireLinkGroup struct {
	Page                  wirePageDescriptor            `json:"page,omitempty"`
	ConfigurationResource wireLinkConfigurationResource `json:"configuration_resource"`
	Presence              []struct {
		Workspace    string    `json:"workspace"`
		Exists       *bool     `json:"exists" nullable:"true"`
		SessionCount int64     `json:"session_count"`
		Host         *wireHost `json:"host" nullable:"true"`
	} `json:"presence"`
	Next *string `json:"next" nullable:"true"`
}

type wireLogin struct {
	ID           string          `json:"id"`
	Provider     string          `json:"provider"`
	URL          *string         `json:"url" nullable:"true"`
	ExpiresAt    string          `json:"expires_at"`
	State        string          `json:"state"`
	Instructions *string         `json:"instructions" nullable:"true"`
	Progress     string          `json:"progress"`
	Accounts     []wireAccount   `json:"accounts"`
	Failure      *wireSafeReason `json:"failure" nullable:"true"`
}

type wireLoginProvider struct {
	ID     string          `json:"id"`
	Label  string          `json:"label"`
	Detail string          `json:"detail"`
	Flows  []string        `json:"flows"`
	Fields []wireFormField `json:"fields"`
}

type wireMCPDefinition struct {
	Enabled           bool                       `json:"enabled"`
	Transport         string                     `json:"transport"`
	Command           *string                    `json:"command" nullable:"true"`
	Arguments         []string                   `json:"arguments"`
	Cwd               *string                    `json:"cwd" nullable:"true"`
	URL               *string                    `json:"url" nullable:"true"`
	Environment       map[string]wireValueSource `json:"environment"`
	Headers           map[string]wireValueSource `json:"headers"`
	BearerTokenEnvVar *string                    `json:"bearer_token_env_var" nullable:"true"`
	EnabledTools      []string                   `json:"enabled_tools" nullable:"true"`
	DisabledTools     []string                   `json:"disabled_tools"`
	StartupTimeoutMs  int64                      `json:"startup_timeout_ms"`
	CallTimeoutMs     int64                      `json:"call_timeout_ms"`
	SecretPresence    wireSecretPresence         `json:"secret_presence"`
}

type wireMCPSettings struct {
	Definitions map[string]wireMCPDefinition `json:"definitions"`
}

type wireMailMetadata struct {
	MailID            string  `json:"mail_id"`
	SenderSessionID   *string `json:"sender_session_id" nullable:"true"`
	ReceiverSessionID string  `json:"receiver_session_id"`
	Kind              string  `json:"kind"`
	Bytes             int64   `json:"bytes"`
	SenderLabel       *string `json:"sender_label" nullable:"true"`
}

type wireModel struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Efforts []struct {
		ID    string `json:"id"`
		Label string `json:"label"`
	} `json:"efforts"`
	DefaultContextTokens   *int64   `json:"default_context_tokens" nullable:"true"`
	EffectiveContextTokens *int64   `json:"effective_context_tokens" nullable:"true"`
	MaxContextTokens       *int64   `json:"max_context_tokens" nullable:"true"`
	MaxOutputTokens        *int64   `json:"max_output_tokens" nullable:"true"`
	InputModalities        []string `json:"input_modalities"`
	ImageEdge              *int64   `json:"image_edge" nullable:"true"`
	Raised                 bool     `json:"raised"`
	CapKey                 string   `json:"cap_key"`
	CachePolicy            struct {
		TTLSeconds *int64  `json:"ttl_seconds" nullable:"true"`
		Source     *string `json:"source" nullable:"true"`
	} `json:"cache_policy"`
	Source     string  `json:"source"`
	ObservedAt *string `json:"observed_at" nullable:"true"`
}

type wireModelPage struct {
	Items []wireModel `json:"items"`
	Next  *string     `json:"next" nullable:"true"`
}

type wireModelReloadOutcome struct {
	Provider   string          `json:"provider"`
	State      string          `json:"state"`
	ObservedAt *string         `json:"observed_at" nullable:"true"`
	Failure    *wireSafeReason `json:"failure" nullable:"true"`
}

type wireModelSettings struct {
	RaisedCaps     map[string]bool  `json:"raised_caps"`
	CacheTTLPriors []wireCachePrior `json:"cache_ttl_priors"`
}

type wireNotification struct {
	State  string  `json:"state"`
	Code   *string `json:"code" nullable:"true"`
	Detail *string `json:"detail" nullable:"true"`
}

type wirePageAction struct {
	ID           string              `json:"id"`
	Label        string              `json:"label"`
	KeyboardHint *string             `json:"keyboard_hint" nullable:"true"`
	Confirmation *string             `json:"confirmation" nullable:"true"`
	Fields       []wireFormField     `json:"fields"`
	Operation    wireActionOperation `json:"operation"`
}

type wirePageDescriptor struct {
	Title      string           `json:"title"`
	EmptyState string           `json:"empty_state"`
	Rows       []wirePageRow    `json:"rows"`
	Glance     *wireGlance      `json:"glance" nullable:"true"`
	Actions    []wirePageAction `json:"actions"`
	Summary    string           `json:"summary"`
}

type wirePageRow struct {
	ID       string  `json:"id"`
	Text     string  `json:"text"`
	Badge    *string `json:"badge" nullable:"true"`
	Tone     string  `json:"tone"`
	Detail   *string `json:"detail" nullable:"true"`
	Resource *struct {
		URL   string          `json:"url"`
		ETag  string          `json:"etag"`
		Value json.RawMessage `json:"value"`
	} `json:"resource" nullable:"true"`
}

type wirePaperclip struct {
	ID                 string  `json:"id"`
	Topic              string  `json:"topic"`
	Title              string  `json:"title"`
	Message            string  `json:"message"`
	Suggestion         string  `json:"suggestion"`
	Reply              string  `json:"reply"`
	Status             string  `json:"status"`
	SessionID          *string `json:"session_id" nullable:"true"`
	Workspace          *string `json:"workspace" nullable:"true"`
	CreatedAt          string  `json:"created_at"`
	UpdatedAt          string  `json:"updated_at"`
	Resolution         string  `json:"resolution"`
	ResolvingSessionID *string `json:"resolving_session_id" nullable:"true"`
	Revision           string  `json:"revision"`
}

type wirePaperclipChange struct {
	Resource     wirePaperclipResource `json:"resource"`
	Notification wireNotification      `json:"notification"`
}

type wirePaperclipPage struct {
	Items  []wirePaperclipResource `json:"items"`
	Next   *string                 `json:"next" nullable:"true"`
	Page   wirePageDescriptor      `json:"page,omitempty"`
	Glance wireGlance              `json:"glance,omitempty"`
}

type wirePaperclipResource struct {
	URL   string        `json:"url"`
	ETag  string        `json:"etag"`
	Value wirePaperclip `json:"value"`
}

type wirePendingInput struct {
	ID              string          `json:"id"`
	Kind            string          `json:"kind"`
	Preview         wirePreview     `json:"preview"`
	AcceptedAt      string          `json:"accepted_at"`
	AcceptanceOrder int64           `json:"acceptance_order"`
	Delivery        string          `json:"delivery"`
	BlockingReason  *wireSafeReason `json:"blocking_reason" nullable:"true"`
}

type wirePreview struct {
	Text            string `json:"text"`
	TranscriptCount int64  `json:"transcript_count"`
	Truncated       bool   `json:"truncated"`
}

type wireProblem struct {
	Type   string `json:"type"`
	Title  string `json:"title"`
	Status int64  `json:"status"`
	Detail string `json:"detail"`
	Code   string `json:"code"`
	Fields []struct {
		Pointer string `json:"pointer"`
		Detail  string `json:"detail"`
	} `json:"fields,omitempty"`
	Decision json.RawMessage `json:"decision,omitempty"`
}

type wireProgressPreview struct {
	OffsetScalars int64  `json:"offset_scalars"`
	Text          string `json:"text"`
}

type wireProviderProfile struct {
	Extension string  `json:"extension"`
	Endpoint  *string `json:"endpoint" nullable:"true"`
	Protocol  string  `json:"protocol"`
	Model     string  `json:"model"`
	Effort    *string `json:"effort" nullable:"true"`
	ImageEdge *int64  `json:"image_edge" nullable:"true"`
	AccountID *string `json:"account_id" nullable:"true"`
	HasKey    bool    `json:"has_key"`
}

type wireProviderRequestRecord struct {
	Sequence            int64                `json:"sequence"`
	Provider            string               `json:"provider"`
	Model               string               `json:"model"`
	RunID               *string              `json:"run_id" nullable:"true"`
	StartedAt           string               `json:"started_at"`
	EndedAt             *string              `json:"ended_at" nullable:"true"`
	PromptTokens        wireTokenObservation `json:"prompt_tokens"`
	CompletionTokens    wireTokenObservation `json:"completion_tokens"`
	CachedTokens        wireTokenObservation `json:"cached_tokens"`
	Failure             *wireSafeReason      `json:"failure" nullable:"true"`
	Kind                string               `json:"kind"`
	ProviderProfile     string               `json:"provider_profile"`
	AccountID           *string              `json:"account_id" nullable:"true"`
	Outcome             string               `json:"outcome"`
	HTTPStatus          *int64               `json:"http_status" nullable:"true"`
	CacheCreationTokens wireTokenObservation `json:"cache_creation_tokens"`
	CacheWrite5mTokens  wireTokenObservation `json:"cache_write_5m_tokens"`
	CacheWrite1hTokens  wireTokenObservation `json:"cache_write_1h_tokens"`
	ReasoningTokens     wireTokenObservation `json:"reasoning_tokens"`
	HeadHash            string               `json:"head_hash"`
	InputCount          int64                `json:"input_count"`
	ReplacedInputCount  *int64               `json:"replaced_input_count" nullable:"true"`
	ProjectionHash      *string              `json:"projection_hash" nullable:"true"`
	Strategy            *string              `json:"strategy" nullable:"true"`
	CacheMarks          []struct {
		Through    string `json:"through"`
		Index      *int64 `json:"index" nullable:"true"`
		TTLSeconds int64  `json:"ttl_seconds"`
	} `json:"cache_marks"`
	TranscriptPositions []int64 `json:"transcript_positions"`
}

type wireProviderSettings struct {
	DefaultProfile *string                        `json:"default_profile" nullable:"true"`
	Profiles       map[string]wireProviderProfile `json:"profiles"`
}

type wireQuarantineDiagnostic struct {
	ID     string         `json:"id"`
	Reason wireSafeReason `json:"reason"`
}

type wireQuotaObservation struct {
	Sequence      int64           `json:"sequence"`
	Provider      string          `json:"provider"`
	AccountID     string          `json:"account_id"`
	LimitID       string          `json:"limit_id"`
	Label         string          `json:"label"`
	Plan          *string         `json:"plan" nullable:"true"`
	UsedPercent   *float64        `json:"used_percent" nullable:"true"`
	WindowLabel   *string         `json:"window_label" nullable:"true"`
	WindowSeconds *int64          `json:"window_seconds" nullable:"true"`
	ResetsAt      *string         `json:"resets_at" nullable:"true"`
	Scope         *string         `json:"scope" nullable:"true"`
	Status        string          `json:"status"`
	Source        string          `json:"source"`
	Error         *wireSafeReason `json:"error" nullable:"true"`
	ObservedAt    string          `json:"observed_at"`
}

type wireQuotaPage struct {
	Items []wireQuotaObservation `json:"items"`
	Next  *string                `json:"next" nullable:"true"`
}

type wireRecentWorkspace struct {
	Location   string  `json:"location"`
	UseCount   int64   `json:"use_count"`
	ActivityAt *string `json:"activity_at" nullable:"true"`
}

type wireRecentWorkspacePage struct {
	Items []wireRecentWorkspace `json:"items"`
	Next  *string               `json:"next" nullable:"true"`
}

type wireReloadResult struct {
	CachePolicy *wireCachePolicyReloadOutcome `json:"cache_policy" nullable:"true"`
	Session     *wireSessionReloadOutcome     `json:"session" nullable:"true"`
	Models      []wireModelReloadOutcome      `json:"models"`
}

type wireRequestRecordPage struct {
	Items []wireProviderRequestRecord `json:"items"`
	Next  *string                     `json:"next" nullable:"true"`
}

type wireResourceValidator struct {
	URL  string `json:"url"`
	ETag string `json:"etag"`
}

type wireSafeReason struct {
	Code   string `json:"code"`
	Detail string `json:"detail"`
}

type wireScheduleChange struct {
	Resource     wireScheduleResource `json:"resource"`
	Notification wireNotification     `json:"notification"`
}

type wireScheduleJob struct {
	ID           string  `json:"id"`
	SessionID    string  `json:"session_id"`
	Kind         string  `json:"kind"`
	Prompt       string  `json:"prompt"`
	NextAt       string  `json:"next_at"`
	EverySeconds *int64  `json:"every_seconds" nullable:"true"`
	Revision     string  `json:"revision"`
	CreatedAt    *string `json:"created_at" nullable:"true"`
	UpdatedAt    *string `json:"updated_at" nullable:"true"`
}

type wireSchedulePage struct {
	Items  []wireScheduleResource `json:"items"`
	Next   *string                `json:"next" nullable:"true"`
	Page   wirePageDescriptor     `json:"page,omitempty"`
	Glance wireGlance             `json:"glance,omitempty"`
}

type wireScheduleResource struct {
	URL   string          `json:"url"`
	ETag  string          `json:"etag"`
	Value wireScheduleJob `json:"value"`
}

type wireSecretPresence struct {
	BearerToken bool     `json:"bearer_token"`
	Environment []string `json:"environment"`
	Headers     []string `json:"headers"`
}

type wireSelectionOverrides struct {
	Extensions   map[string]*bool `json:"extensions"`
	Skills       map[string]*bool `json:"skills"`
	Instructions map[string]*bool `json:"instructions"`
	MCP          map[string]*bool `json:"mcp"`
}

type wireServer struct {
	InstanceID   string           `json:"instance_id"`
	Protocol     int64            `json:"protocol"`
	State        string           `json:"state"`
	Capabilities map[string]int64 `json:"capabilities"`
	Build        *string          `json:"build" nullable:"true"`
	Digest       *string          `json:"digest" nullable:"true"`
	Extensions   []struct {
		Name    string `json:"name"`
		Version int64  `json:"version"`
	} `json:"extensions"`
	Quota   []wireQuotaObservation `json:"quota" nullable:"true"`
	Notices []struct {
		ID      string `json:"id"`
		Kind    string `json:"kind"`
		Message string `json:"message"`
	} `json:"notices"`
	QuotaHistory wireQuotaPage `json:"quota_history,omitempty"`
}

type wireSession struct {
	ID                    string                           `json:"id"`
	Name                  string                           `json:"name"`
	AutomaticName         string                           `json:"automatic_name"`
	Location              wireSessionLocation              `json:"location"`
	Workspace             string                           `json:"workspace"`
	ParentID              *string                          `json:"parent_id" nullable:"true"`
	RootID                string                           `json:"root_id"`
	Address               *string                          `json:"address" nullable:"true"`
	Depth                 int64                            `json:"depth"`
	Closed                bool                             `json:"closed"`
	CreatedAt             *string                          `json:"created_at" nullable:"true"`
	ActivityAt            *string                          `json:"activity_at" nullable:"true"`
	ProviderProfile       *string                          `json:"provider_profile" nullable:"true"`
	Model                 *string                          `json:"model" nullable:"true"`
	Effort                *string                          `json:"effort" nullable:"true"`
	Status                wireSessionStatus                `json:"status"`
	Preview               wirePreview                      `json:"preview"`
	Preferences           wireSessionPreferences           `json:"preferences"`
	CurrentProgress       []wireToolProgress               `json:"current_progress"`
	Activity              wireActivity                     `json:"activity"`
	Cursor                *wireCursor                      `json:"cursor" nullable:"true"`
	Creation              *wireCreation                    `json:"creation" nullable:"true"`
	Revision              string                           `json:"revision"`
	FamilyRevision        string                           `json:"family_revision"`
	ConfigurationResource wireSessionConfigurationResource `json:"configuration_resource"`
	WorkspaceChange       *wireWorkspaceChange             `json:"workspace_change" nullable:"true"`
	Selection             wireSessionSelection             `json:"selection"`
	Composition           wireComposition                  `json:"composition"`
	Kernel                wireKernel                       `json:"kernel"`
	PendingInputs         []wirePendingInput               `json:"pending_inputs"`
	InputOrder            int64                            `json:"input_order"`
	Usage                 wireUsage                        `json:"usage"`
	History               wireHistoryPage                  `json:"history"`
	Glances               []wireGlance                     `json:"glances"`
}

type wireSessionChange struct {
	Resource wireSessionConfigurationResource `json:"resource"`
	Session  wireSession                      `json:"session"`
	Move     *struct {
		AppliedCount  int64        `json:"applied_count"`
		DeferredCount int64        `json:"deferred_count"`
		AppliedIDs    []string     `json:"applied_ids"`
		DeferredIDs   []string     `json:"deferred_ids"`
		Truncated     bool         `json:"truncated"`
		Warnings      wireWarnings `json:"warnings"`
	} `json:"move" nullable:"true"`
}

type wireSessionConfiguration struct {
	ID              string  `json:"id"`
	Name            string  `json:"name"`
	Workspace       string  `json:"workspace"`
	ProviderProfile *string `json:"provider_profile" nullable:"true"`
	Model           *string `json:"model" nullable:"true"`
	Effort          *string `json:"effort" nullable:"true"`
	Preferences     struct {
		Pinned   bool   `json:"pinned"`
		PinOrder *int64 `json:"pin_order" nullable:"true"`
		Archived bool   `json:"archived"`
	} `json:"preferences"`
	Selection      wireSelectionOverrides `json:"selection"`
	Revision       string                 `json:"revision"`
	FamilyRevision string                 `json:"family_revision"`
}

type wireSessionConfigurationResource struct {
	URL   string                   `json:"url"`
	ETag  string                   `json:"etag"`
	Value wireSessionConfiguration `json:"value"`
}

type wireSessionDeletion struct {
	State          string   `json:"state"`
	DeletedCount   int64    `json:"deleted_count"`
	RemainingCount int64    `json:"remaining_count"`
	DeletedIDs     []string `json:"deleted_ids"`
	Remaining      []struct {
		ID     string         `json:"id"`
		Reason wireSafeReason `json:"reason"`
	} `json:"remaining"`
	Truncated bool `json:"truncated"`
}

type wireSessionLocation struct {
	Host  *string `json:"host" nullable:"true"`
	User  *string `json:"user" nullable:"true"`
	Path  string  `json:"path"`
	Label *string `json:"label" nullable:"true"`
}

type wireSessionPage struct {
	Items  []wireSessionSummary `json:"items"`
	Next   *string              `json:"next" nullable:"true"`
	Family struct {
		RootID   string `json:"root_id"`
		Revision string `json:"revision"`
	} `json:"family,omitempty"`
}

type wireSessionPreferences struct {
	Pinned   bool   `json:"pinned"`
	PinOrder *int64 `json:"pin_order" nullable:"true"`
	Archived bool   `json:"archived"`
	Opens    int64  `json:"opens"`
}

type wireSessionReloadOutcome struct {
	State           string          `json:"state"`
	LoadedRevision  *string         `json:"loaded_revision" nullable:"true"`
	RestartRequired bool            `json:"restart_required"`
	Warnings        wireWarnings    `json:"warnings"`
	Failure         *wireSafeReason `json:"failure" nullable:"true"`
}

type wireSessionSelection struct {
	Overrides wireSelectionOverrides `json:"overrides"`
	Effective struct {
		Extensions   map[string]bool `json:"extensions"`
		Skills       map[string]bool `json:"skills"`
		Instructions map[string]bool `json:"instructions"`
		MCP          map[string]bool `json:"mcp"`
	} `json:"effective"`
}

type wireSessionStatus struct {
	Phase              string          `json:"phase"`
	RunID              *string         `json:"run_id" nullable:"true"`
	InterruptRequested bool            `json:"interrupt_requested"`
	BlockingReason     *wireSafeReason `json:"blocking_reason" nullable:"true"`
}

type wireSessionSummary struct {
	ID              string                 `json:"id"`
	Name            string                 `json:"name"`
	AutomaticName   string                 `json:"automatic_name"`
	Location        wireSessionLocation    `json:"location"`
	Workspace       string                 `json:"workspace"`
	ParentID        *string                `json:"parent_id" nullable:"true"`
	RootID          string                 `json:"root_id"`
	Address         *string                `json:"address" nullable:"true"`
	Depth           int64                  `json:"depth"`
	Closed          bool                   `json:"closed"`
	CreatedAt       *string                `json:"created_at" nullable:"true"`
	ActivityAt      *string                `json:"activity_at" nullable:"true"`
	ProviderProfile *string                `json:"provider_profile" nullable:"true"`
	Model           *string                `json:"model" nullable:"true"`
	Effort          *string                `json:"effort" nullable:"true"`
	Status          wireSessionStatus      `json:"status"`
	Preview         wirePreview            `json:"preview"`
	Preferences     wireSessionPreferences `json:"preferences"`
	CurrentProgress []wireToolProgress     `json:"current_progress"`
	Activity        wireActivity           `json:"activity"`
	Cursor          *wireCursor            `json:"cursor" nullable:"true"`
}

type wireSettings struct {
	Providers      wireProviderSettings   `json:"providers"`
	MCP            wireMCPSettings        `json:"mcp"`
	Extensions     wireExtensionSettings  `json:"extensions"`
	Capabilities   wireCapabilitySettings `json:"capabilities"`
	Models         wireModelSettings      `json:"models"`
	UI             wireUISettings         `json:"ui"`
	GroupResources struct {
		Providers    wireResourceValidator `json:"providers"`
		MCP          wireResourceValidator `json:"mcp"`
		Extensions   wireResourceValidator `json:"extensions"`
		Capabilities wireResourceValidator `json:"capabilities"`
		Models       wireResourceValidator `json:"models"`
		UI           wireResourceValidator `json:"ui"`
	} `json:"group_resources"`
}

type wireShutdown struct {
	InstanceID string `json:"instance_id"`
	State      string `json:"state"`
}

type wireStorageFile struct {
	Path             string  `json:"path"`
	Category         string  `json:"category"`
	Bytes            int64   `json:"bytes"`
	ModifiedAt       *string `json:"modified_at" nullable:"true"`
	CleanupCandidate bool    `json:"cleanup_candidate"`
	CleanupReason    *string `json:"cleanup_reason" nullable:"true"`
}

type wireStorageFilePage struct {
	Items  []wireStorageFile `json:"items"`
	Next   *string           `json:"next" nullable:"true"`
	Totals struct {
		KernelBytes       int64 `json:"kernel_bytes"`
		BackupBytes       int64 `json:"backup_bytes"`
		OtherBytes        int64 `json:"other_bytes"`
		RecentBackupBytes int64 `json:"recent_backup_bytes"`
		RecentBackupCount int64 `json:"recent_backup_count"`
	} `json:"totals"`
}

type wireStorageReport struct {
	Database struct {
		MainFileBytes int64 `json:"main_file_bytes"`
		WalBytes      int64 `json:"wal_bytes"`
		PageSizeBytes int64 `json:"page_size_bytes"`
		PageCount     int64 `json:"page_count"`
		FreePageCount int64 `json:"free_page_count"`
		UsedBytes     int64 `json:"used_bytes"`
	} `json:"database"`
	Sessions wireStorageSessionPage `json:"sessions"`
	Images   struct {
		Count int64 `json:"count"`
		Bytes int64 `json:"bytes"`
	} `json:"images"`
	Files      wireStorageFilePage `json:"files"`
	MeasuredAt string              `json:"measured_at"`
}

type wireStorageSession struct {
	ID                    string  `json:"id"`
	Title                 string  `json:"title"`
	Workspace             string  `json:"workspace"`
	CreatedAt             *string `json:"created_at" nullable:"true"`
	ActivityAt            *string `json:"activity_at" nullable:"true"`
	EstimatedContentBytes int64   `json:"estimated_content_bytes"`
}

type wireStorageSessionPage struct {
	Items                      []wireStorageSession `json:"items"`
	Next                       *string              `json:"next" nullable:"true"`
	TotalCount                 int64                `json:"total_count"`
	TotalEstimatedContentBytes int64                `json:"total_estimated_content_bytes"`
}

type wireTargetNotification struct {
	SessionID    string           `json:"session_id"`
	Notification wireNotification `json:"notification"`
}

type wireTokenObservation struct {
	Estimated *int64  `json:"estimated" nullable:"true"`
	Observed  *int64  `json:"observed" nullable:"true"`
	Source    *string `json:"source" nullable:"true"`
}

type wireToolActivity struct {
	Kind   string `json:"kind"`
	Target string `json:"target"`
}

type wireToolProgress struct {
	CallID     string              `json:"call_id"`
	ToolCallID *string             `json:"tool_call_id" nullable:"true"`
	Name       string              `json:"name"`
	Phase      string              `json:"phase"`
	Intent     string              `json:"intent"`
	Preview    wireProgressPreview `json:"preview,omitempty"`
}

type wireToolTrace struct {
	Activities []wireToolActivity `json:"activities"`
	Changes    []json.RawMessage  `json:"changes"`
	Truncated  bool               `json:"truncated"`
}

type wireTreeChild struct {
	Name     string  `json:"name"`
	Kind     string  `json:"kind"`
	Location string  `json:"location"`
	Language *string `json:"language" nullable:"true"`
	Changed  int64   `json:"changed"`
}

type wireTreeEntry struct {
	Name     string          `json:"name"`
	Kind     string          `json:"kind"`
	Location string          `json:"location"`
	Children []wireTreeChild `json:"children"`
	More     int64           `json:"more"`
	Language *string         `json:"language" nullable:"true"`
	Changed  int64           `json:"changed"`
}

type wireTurn struct {
	ID        string          `json:"id"`
	State     string          `json:"state"`
	StartedAt string          `json:"started_at"`
	EndedAt   *string         `json:"ended_at" nullable:"true"`
	Outcome   *wireSafeReason `json:"outcome" nullable:"true"`
}

type wireUISettings struct {
	Thinking         bool     `json:"thinking"`
	Tools            bool     `json:"tools"`
	DismissedNotices []string `json:"dismissed_notices"`
}

type wireUsage struct {
	Model               *string  `json:"model" nullable:"true"`
	ObservedAt          *string  `json:"observed_at" nullable:"true"`
	PromptTokens        *int64   `json:"prompt_tokens" nullable:"true"`
	CachedPromptTokens  *int64   `json:"cached_prompt_tokens" nullable:"true"`
	CacheWriteTokens    *int64   `json:"cache_write_tokens" nullable:"true"`
	CompletionTokens    *int64   `json:"completion_tokens" nullable:"true"`
	TotalTokens         *int64   `json:"total_tokens" nullable:"true"`
	ElapsedMs           *float64 `json:"elapsed_ms" nullable:"true"`
	TokensPerSecond     *float64 `json:"tokens_per_second" nullable:"true"`
	ContextWindowTokens *int64   `json:"context_window_tokens" nullable:"true"`
	CacheTTLSeconds     *int64   `json:"cache_ttl_seconds" nullable:"true"`
	CacheFade           []struct {
		At           string `json:"at"`
		CachedTokens *int64 `json:"cached_tokens" nullable:"true"`
	} `json:"cache_fade"`
}

type wireValueSource struct {
	Source string `json:"source"`
	Value  string `json:"value"`
}

type wireVisit struct {
	VisitID   string `json:"visit_id"`
	SessionID string `json:"session_id"`
	Opens     int64  `json:"opens"`
}

type wireWarnings []wireSafeReason

type wireWorkChange struct {
	Resource     wireWorkResource `json:"resource"`
	Notification wireNotification `json:"notification"`
}

type wireWorkItem struct {
	ID        string  `json:"id"`
	Workspace string  `json:"workspace"`
	Title     string  `json:"title"`
	Notes     string  `json:"notes"`
	ParentID  *string `json:"parent_id" nullable:"true"`
	SessionID *string `json:"session_id" nullable:"true"`
	RunID     *string `json:"run_id" nullable:"true"`
	Status    string  `json:"status"`
	Revision  string  `json:"revision"`
	CreatedAt string  `json:"created_at"`
	UpdatedAt string  `json:"updated_at"`
}

type wireWorkPage struct {
	Items  []wireWorkResource `json:"items"`
	Next   *string            `json:"next" nullable:"true"`
	Page   wirePageDescriptor `json:"page,omitempty"`
	Glance wireGlance         `json:"glance,omitempty"`
}

type wireWorkResource struct {
	URL   string       `json:"url"`
	ETag  string       `json:"etag"`
	Value wireWorkItem `json:"value"`
}

type wireWorkspaceChange struct {
	Desired  string `json:"desired"`
	Active   string `json:"active"`
	State    string `json:"state"`
	Revision string `json:"revision"`
}

type wireWorkspaceDirectory struct {
	Directory string    `json:"directory"`
	Parent    *string   `json:"parent" nullable:"true"`
	Home      *string   `json:"home" nullable:"true"`
	Host      *wireHost `json:"host" nullable:"true"`
	Items     []struct {
		Name       string  `json:"name"`
		Location   string  `json:"location"`
		Vcs        *string `json:"vcs" nullable:"true"`
		ModifiedAt *string `json:"modified_at" nullable:"true"`
		Hidden     bool    `json:"hidden"`
	} `json:"items"`
	Next    *string              `json:"next" nullable:"true"`
	Preview wireWorkspacePreview `json:"preview,omitempty"`
}

type wireWorkspacePreview struct {
	Repository           json.RawMessage `json:"repository" nullable:"true"`
	RepositoryDiagnostic *wireSafeReason `json:"repository_diagnostic" nullable:"true"`
	Languages            []struct {
		Name  string  `json:"name"`
		Bytes int64   `json:"bytes"`
		Share float64 `json:"share"`
		Color *string `json:"color" nullable:"true"`
	} `json:"languages"`
	Tree []wireTreeEntry `json:"tree"`
	More int64           `json:"more"`
}
