// Supabase Edge Function: send-push
// Called by a Database Webhook every time a row is inserted into "notifications".
// Sends a push message to every device that user has turned on.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT")!,      // for example: mailto:you@gmail.com
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

Deno.serve(async (req) => {
  // Only our own webhook may call this function.
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) {
    return new Response("Unauthorized", { status: 401 });
  }

  const { record } = await req.json();
  if (!record?.user_id) return new Response("ignored");

  const { data: subs } = await admin
    .from("push_subscriptions")
    .select("id, endpoint, p256dh, auth")
    .eq("user_id", record.user_id);

  const payload = JSON.stringify({ title: "StudySync", body: record.message, url: "/" });
  let sent = 0;

  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
      );
      sent++;
    } catch (e) {
      // The device is gone (app removed, permission revoked): forget it.
      if (e.statusCode === 404 || e.statusCode === 410) {
        await admin.from("push_subscriptions").delete().eq("id", s.id);
      }
    }
  }));

  return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
});
