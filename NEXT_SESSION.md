# Próxima sesión · Módulo "Organizador de Proyectos"

## Dominio

La app se sirve **solo** en **https://app.organizadisimos.com**.
El 22 jul 2026 se sacó academiapex por completo de Vercel: `academiapex.com` y
`www.academiapex.com` se desconectaron de este proyecto, `app.academiapex.com`
se desconectó de `systems-canvas` (que vive en `app.canvaspex.com`) y el dominio
se quitó de la cuenta. Los tres devuelven 404. No volver a usarlo.

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
- Reordenar con flechas ▲▼ en áreas, tareas y subtareas: al mover se reescribe
  la `position` de toda la lista de hermanos, así que el orden que se ve es
  siempre el que queda guardado.

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

## Aislamiento entre empresas · verificado el 22 jul 2026

Probado en SQL suplantando identidades (`set role authenticated` +
`request.jwt.claims`), con una fila semilla en dos cuentas distintas:

| Prueba | Resultado |
|---|---|
| Cliente A: proyectos visibles | solo el suyo |
| Cliente B: proyectos visibles | solo el suyo |
| A modifica el proyecto de B | 0 filas afectadas |
| A elimina el proyecto de B | 0 filas afectadas |
| A crea un proyecto dentro de la cuenta de B | rechazado (42501) |
| Cuenta desactivada: proyectos visibles | ninguno |
| Cuenta desactivada: `is_active_user()` | false |

Ni A ni B vieron nunca los proyectos del propietario. Las filas semilla se
borraron al terminar. Para repetirlo: el auto-registro está cerrado (422), así
que no hacen falta cuentas nuevas — basta suplantar en el SQL Editor.

## Trabajo pendiente

1. **Sitio comercial** en el ápice `organizadisimos.com`: landing, precios,
   FAQ, blog. **Decisión del 22 jul 2026: se pospone a propósito.** El ápice
   se queda como está (parking de GoDaddy, sin apuntar a Vercel) hasta que se
   construya el sitio; no redirigirlo a la app mientras tanto.
2. **Cambios dentro de la app**, que es la prioridad siguiente: ajustes tanto
   en la vista de administración (`/admin/`) como en la del usuario
   (`/dashboard/` y `/proyectos/`). Sin definir todavía.

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
