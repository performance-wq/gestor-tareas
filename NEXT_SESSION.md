# Próxima sesión · Módulo "Organizador de Proyectos"

## Dominio

La app se sirve **solo** en **https://app.organizadisimos.com**.
El 22 jul 2026 se desconectaron `academiapex.com` y `www.academiapex.com` del
proyecto de Vercel: ya devuelven 404. No volver a usar ese dominio aquí.

## Estado

El módulo está **construido y en producción**:

- `sql/004-organizador-de-proyectos.sql` **ejecutado** en Supabase
  (`hwisrkincpkkdqrxuoch`). Verificado por API: las cuatro tablas responden y
  un insert anónimo se rechaza con `42501` (RLS activa).
- `/proyectos/index.html` publicado: lista de proyectos, vista de proyecto con
  % de avance global y contadores, pestañas **Tareas** y **Bitácora**, tareas
  agrupadas por área, subtareas, estado automático y seguimiento opcional.
- Guard de acceso: `sb.rpc('is_active_user')` tras autenticar, con el aviso
  "Tu cuenta está desactivada. Contacta al administrador."
- Navegación: enlace "Proyectos" en `/dashboard/` y en `/admin/`, y "Tareas"
  de vuelta desde `/proyectos/`.

## Qué es este módulo

Herramienta para ejecutar un proyecto completo (lanzamiento, webinar, embudo,
campaña, onboarding...). **Independiente del gestor de Tareas**, que no se toca:
Tareas = pendientes individuales y rápidos; Organizador = ejecución de proyectos.

Regla de producto: si algo no sirve a uno de estos tres pilares, no se implementa.

1. **Organizar** — proyecto → áreas/fases → tareas → subtareas. Avance por tarea
   = % de subtareas completadas; avance del proyecto = promedio de sus tareas.
   El avance se **deriva en el cliente**, nunca se persiste.
2. **Seguimiento** — opcional por tarea, con indicadores libres que cada tarea
   define (webinar: inscritos/show rate; campaña: CPL/ROAS; landing: visitas/leads).
   Sin dashboards ni gráficos.
3. **Bitácora** — historial técnico: fecha, área, cambio, motivo, resultado y
   observaciones. No es un chat.

## Trabajo pendiente

1. **Prueba E2E con dos cuentas de cliente reales**: crear proyecto, áreas,
   tareas, subtareas y bitácora; y confirmar **por API** (no solo por UI) que
   la cuenta A no puede leer ni escribir los `projects` de la cuenta B.
   Requiere credenciales de dos cuentas de prueba.
2. **Limpiar academiapex del resto de la cuenta**: `app.academiapex.com` sigue
   enganchado al proyecto `systems-canvas`, que ya vive en `app.canvaspex.com`.
3. **Ápice `organizadisimos.com`**: todavía no apunta a Vercel (falta el
   registro `A 76.76.21.21` en GoDaddy). Queda libre para el sitio comercial.
4. **Orden de áreas y tareas**: `position` se guarda pero no hay forma de
   reordenar desde la UI.

## Contexto de la plataforma

- Rutas: `/` acceso y enrutado por rol · `/dashboard/` Tareas · `/admin/` panel
  del propietario · `/proyectos/` Organizador.
- Multi-tenant: todo cuelga de `account_id`; las políticas filtran por
  `current_account_id()` y exigen `is_active_user()` (usuario **y** empresa activos).
- El auto-registro está deshabilitado en Supabase: las cuentas solo se crean
  desde `/admin` mediante la Edge Function `admin-create-user`.

## Referencia útil

Ya se construyó un módulo equivalente en el repo **systems-canvas**
(`app/projects/[projectId]/execution/` y `lib/domain/execution.ts`): sirve de
guía para el cálculo de avance y la estructura de componentes.
