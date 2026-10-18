export async function dispatchPush(transport, token, environment, payload, style = "liveactivity") {
  const result = await transport.send(token, environment, payload, style);
  if (!result) return { kind: "unavailable" };
  if (result.status === 410) return { kind: "disabled" };
  if (result.status === 429) return { kind: "backoff" };
  return result.status >= 200 && result.status < 300 ? { kind: "sent" } : { kind: "failed" };
}

export function buildActivityPayload(data, endsAt, eventTimestamp) {
  const seconds = (value) => value === null ? null : Math.floor(Date.parse(value) / 1000);
  const staleAt = seconds(data.staleAt);
  const endAt = Math.floor(Date.parse(endsAt) / 1000);
  return { aps: { timestamp: eventTimestamp, event: "update", "content-state": { remainingBps: data.remainingBps, displayState: data.displayState, observedAt: seconds(data.observedAt), staleAt, resetsAt: seconds(data.resetsAt), label: data.label, sequence: data.sequence }, "stale-date": staleAt === null ? endAt : Math.min(staleAt, endAt) } };
}
