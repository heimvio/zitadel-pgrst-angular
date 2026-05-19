import { Routes } from '@angular/router';
import { authGuard } from '../auth';
import { ProductsComponent } from './products.component';
import { CallbackComponent } from './callback.component';

export const routes: Routes = [
  { path: '', component: ProductsComponent, canActivate: [authGuard] },
  { path: 'callback', component: CallbackComponent },
  { path: '**', redirectTo: '' }
];
