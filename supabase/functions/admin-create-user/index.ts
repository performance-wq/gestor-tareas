// Organizadísimos · Edge Function: admin-create-user
//
// Crea una cuenta de cliente (correo + contraseña) desde el panel de administración.
// Vive en el servidor porque usa la llave SERVICE_ROLE, que NUNCA puede estar en el
// navegador: quien la tuviera podría leer y borrar toda la base de datos.
//
// Regla de acceso: solo un usuario con profiles.role = 'owner' puede invocarla.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Método no permitido." }, 405);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 1) Identificar a quien llama a partir de su sesión.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Falta la sesión." }, 401);

  const { data: caller, error: callerErr } = await admin.auth.getUser(token);
  if (callerErr || !caller?.user) return json({ error: "Sesión inválida." }, 401);

  // 2) Solo el propietario de la plataforma administra cuentas.
  const { data: prof } = await admin
    .from("profiles")
    .select("role")
    .eq("id", caller.user.id)
    .single();

  if (!prof || prof.role !== "owner") {
    return json({ error: "Solo el propietario puede administrar cuentas." }, 403);
  }

  // 3) Validar los datos de la cuenta nueva.
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Cuerpo de la petición inválido." }, 400);
  }

  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  const company = body.company ? String(body.company).trim() : null;
  const fullName = body.full_name ? String(body.full_name).trim() : null;
  // Estado inicial (§8): por defecto 'pending'; el dueño puede crear ya activo.
  let status = String(body.status ?? "pending").trim().toLowerCase();
  if (!["pending", "active", "suspended"].includes(status)) status = "pending";

  if (!email.includes("@")) return json({ error: "El correo no es válido." }, 400);
  if (password.length < 8) {
    return json({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
  }

  // 4) Idempotencia (§11/§16): si ya existe un perfil con ese correo, no crear
  //    otra cuenta; devolver el existente para que el panel ofrezca opciones.
  const { data: dup } = await admin
    .from("profiles").select("id, account_id, status, role")
    .ilike("email", email).maybeSingle();
  if (dup) {
    return json({ existing: true, id: dup.id, email, status: dup.status, role: dup.role, account_id: dup.account_id });
  }

  // Crear el usuario ya confirmado: entra directo con las credenciales, sin
  // depender de correos de validación (no se envía correo alguno).
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });

  if (createErr) {
    if (/already/i.test(createErr.message)) {
      const { data: ex } = await admin.from("profiles").select("id, account_id, status, role").ilike("email", email).maybeSingle();
      if (ex) return json({ existing: true, id: ex.id, email, status: ex.status, role: ex.role, account_id: ex.account_id });
      return json({ error: "Ya existe una cuenta con ese correo." }, 400);
    }
    return json({ error: createErr.message }, 400);
  }

  // 5) Completar el perfil. El trigger on_auth_user_created ya creó la fila y,
  //    con ella, la cuenta (tenant) propia de este cliente.
  const { data: profile, error: updErr } = await admin
    .from("profiles")
    .update({ role: "client", status, active: status === "active", company, full_name: fullName })
    .eq("id", created.user!.id)
    .select("account_id")
    .single();

  if (updErr) return json({ error: updErr.message }, 500);

  // 6) La cuenta nace con el correo por nombre: si nos dieron la empresa,
  //    se renombra para que el panel muestre algo legible.
  if (company && profile?.account_id) {
    await admin.from("accounts").update({ name: company }).eq("id", profile.account_id);
  }

  return json({ ok: true, id: created.user!.id, email, account_id: profile?.account_id ?? null });
});
