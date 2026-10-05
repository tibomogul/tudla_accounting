TudlaAccounting::Engine.routes.draw do
  root to: "dashboard#index"

  resources :accounts
  resources :periods, only: %i[index show new create destroy]
end
