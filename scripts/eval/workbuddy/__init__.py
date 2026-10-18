"""WorkBuddy-Bench integration owned by the metacodes repository."""

WORKBUDDY_PINNED_COMMIT = "b516950be5b56eb3be406c2f76ee1c5111dcb57f"
# The Web/Office LLM judge's credential (`judge-kimi-k27.yaml` backend_key_env).
# Only a paid launch planned with a judge budget keeps it in the runner's
# environment (launch_gate); every other runner here removes it.
WORKBUDDY_JUDGE_KEY_ENV = "METACODES_WORKBUDDY_JUDGE_API_KEY"
