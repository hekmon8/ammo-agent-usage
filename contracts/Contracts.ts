/** DTO/interface examples only. Runtime validation must use the JSON schemas. */
export type Availability = 'available' | 'unavailable' | 'unlimited';
export type FetchOutcome = 'ok' | 'auth_required' | 'error' | 'throttled' | 'disabled';
export type SourceMethod = 'official_api' | 'local_rpc' | 'local_file' | 'community_endpoint' | 'user_defined';
export interface WindowDefinition {
  kind: 'rolling' | 'fixed' | 'calendar' | 'unknown';
  durationSeconds: number | null;
  startsAt: string | null; resetsAt: string | null; periodId: string | null;
}
export interface HistoryPoint { observedAt: string; remainingBps: number | null; segmentId: string; }
export interface QuotaWindow {
  id: string; providerId: string; accountId: string; accountAlias: string;
  quotaKey: string; sharedPoolId: string | null;
  unit: 'percent' | 'tokens' | 'requests' | 'credits' | 'money'; currency: string | null;
  availability: Availability; remainingBps: number | null; amount: string | null; limit: string | null;
  quality: 'reported' | 'estimated' | 'unknown'; sourceMethod: SourceMethod;
  fetchOutcome: FetchOutcome; observedAt: string | null; staleAt: string | null;
  window: WindowDefinition; history: HistoryPoint[];
}
export interface Snapshot {
  schemaVersion: '1.0.0'; snapshotId: string; sourceDeviceId: string;
  sourceEpoch: string; sourceSequence: number; capturedAt: string; windows: QuotaWindow[];
}
export interface EncryptedEnvelope {
  schemaVersion: '1.0.0'; workspaceId: string; sourceDeviceId: string; sourceEpoch: string;
  sequence: number; keyId: string; nonce: string; ciphertext: string; tag: string;
  signature: string; contentHash: string;
}
export interface PushTransport {
  /** Only a registered activity and an explicitly consented projection may be sent. */
  send(registrationId: string, state: Readonly<LiveProjection>): Promise<PushResult>;
}
export interface LiveProjection {
  sequence: number; windowId: string; label: string; remainingBps: number | null;
  displayState: string; observedAt: string | null; staleAt: string | null; resetsAt: string | null;
}
export type PushResult = { kind: 'accepted' } | { kind: 'retry'; afterSeconds: number } |
  { kind: 'invalid_token' } | { kind: 'configuration_error'; code: string };
