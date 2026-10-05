TudlaAccounting::Engine.routes.draw do
  root to: "dashboard#index"

  resources :accounts
  resources :periods, only: %i[index show new create destroy]
  get "reports", to: "reports#index", as: :reports
  scope "reports", controller: :reports, as: :reports do
    get :balance_sheet
    get :profit_and_loss
    get :trial_balance
    get :receivables
    get :payables
  end

  resources :entries do
    member do
      post :post
      post :reverse
    end
  end
end
