# Próxima sesión · Módulo "Organizador de Proyectos"

## Estado

La base de datos está **escrita pero NO ejecutada**: `sql/004-organizador-de-proyectos.sql`.
Primer paso de la próxima sesión: correrla en el SQL Editor de Supabase
(proyecto `hwisrkincpkkdqrxuoch`) y verificar con una consulta que las 4 tablas
y sus políticas existen.

## Qué es este módulo

Herramienta para ejecutar un proyecto completo (lanzamiento, webinar, embudo,
campaña, onboarding...). **Independiente del gestor de Tareas**, que no se toca:
Tareas = pendientes individuales y rápidos; Organizador = ejecución de proyectos.

Regla de producto: si algo no sirve a uno de estos tres pilares, no se implementa.

1. **Organizar** — proyecto → áreas/fases → tareas → subtareas. Avance por tarea
   = % de subtareas completadas; avance del proyecto = promedio de sus tareas.
2. **Seguimiento** — opcional por tarea, con indicadores libres que cada tarea
   define (webinar: inscritos/show rate; campaña: CPL/ROAS; landing: visitas/leads).
   Sin dashboards ni gráficos.
3. **Bitácora** — historial técnico: fecha, área, cambio, motivo, resultado y
   observaciones. No es un chat.

## Trabajo pendiente

1. **Ejecutar `sql/004`** y verificar.
2. **Crear `/proyectos/index.html`** (misma estructura de página única que
   `/dashboard/` y `/admin/`, mismos tokens de color y tipografía):
   - Lista de proyectos de la cuenta + crear proyecto.
   - Vista de proyecto: cabecera con **% de avance global** y contadores
     (pendiente / en proceso / completado), y dos pestañas: **Tareas** y **Bitácora**.
   - Tareas agrupadas por **área**; cada tarea despliega descripción,
     responsable, prioridad, fecha, estado, subtareas y el bloque de seguimiento.
   - Estado automático cuando la tarea tiene subtareas (todas hechas → completada;
     alguna avanzada → en proceso), para que nunca contradiga la barra de avance.
3. **Navegación**: enlace "Proyectos" en `/dashboard/` y "Tareas" de vuelta,
   más el enlace desde `/admin/`. Es la "sección del menú principal" que pidió.
4. **Guard de acceso**: copiar el de `/dashboard/` — tras autenticarse, llamar a
   `sb.rpc('is_active_user')` y, si es falso, cerrar sesión con el aviso
   "Tu cuenta está desactivada. Contacta al administrador."
5. **Verificar** con una cuenta de cliente real: que solo ve sus proyectos y que
   el aislamiento entre empresas se mantiene (probar por API, no solo por UI).

## Referencia útil

Ya se construyó un módulo equivalente en el repo **systems-canvas**
(`app/projects/[projectId]/execution/` y `lib/domain/execution.ts`): sirve de
guía para el cálculo de avance y la estructura de componentes. Aquí hay que
adaptarlo a HTML/JS de un solo archivo y añadir el nivel de **áreas**, que
aquel no tenía.

## Contexto de la plataforma

- Rutas: `/` acceso y enrutado por rol · `/dashboard/` Tareas · `/admin/` panel
  del propietario · `/proyectos/` (nuevo).
- Multi-tenant: todo cuelga de `account_id`; las políticas filtran por
  `current_account_id()` y exigen `is_active_user()` (usuario **y** empresa activos).
- El auto-registro está deshabilitado en Supabase: las cuentas solo se crean
  desde `/admin` mediante la Edge Function `admin-create-user`.
