import { HttpInterceptorFn, HttpErrorResponse } from '@angular/common/http';
import { inject } from '@angular/core';
import { catchError, from, switchMap, throwError } from 'rxjs';
import { AuthService } from './auth.service';
import { runtimeConfig } from './runtime-config';

/**
 * Hängt den Bearer-Token nur an PostgREST-Requests; bei 401 einmal Token
 * refreshen + Wiederholung, sonst Fehler durchreichen. Generisch.
 */
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(AuthService);
  const isPgrst = !!runtimeConfig.postgrest.url && req.url.startsWith(runtimeConfig.postgrest.url);
  if (!isPgrst) return next(req);

  const withTok = (t: string | null) =>
    t ? req.clone({ setHeaders: { Authorization: `Bearer ${t}` } }) : req;

  return next(withTok(auth.token)).pipe(
    catchError((err: HttpErrorResponse) => {
      if (err.status !== 401) return throwError(() => err);
      return from(auth.refresh()).pipe(
        switchMap(() => next(withTok(auth.token))),
        catchError(e => { auth.logout(); return throwError(() => e); })
      );
    })
  );
};
