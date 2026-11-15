REVOKE EXECUTE ON FUNCTION public.v32_assert_ledger_transaction_balanced() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_escrow_transition_guard() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_immutable_ledger_guard() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_ledger_after_insert() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_ledger_before_insert() FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_invoice_hash(uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.v32_invoice_immutable_guard() FROM PUBLIC,anon,authenticated;