TudlaAccounting::Engine.routes.draw do
  root to: "dashboard#index"

  resources :accounts
  resources :periods, only: %i[index show new create destroy] do
    member do
      post :close
      post :reopen
    end
  end
  get "activity", to: "activity#index", as: :activity
  get "setup", to: "setup#index", as: :setup
  scope "setup", controller: :setup, as: :setup do
    get :opening_balances
    patch :opening_balances, action: :save_opening_balances
    post :chart_of_accounts
    post :open_items
    post :revaluation
    get :balances
    post :balances, action: :rebuild_balances
  end

  get "reports", to: "reports#index", as: :reports
  scope "reports", controller: :reports, as: :reports do
    get :balance_sheet
    get :profit_and_loss
    get :trial_balance
    get :receivables
    get :payables
    get :tax
    get :by_dimension
    get :general_ledger
    get :cash_flow
  end

  resources :tax_codes, except: :show
  resources :dimensions, except: %i[show destroy] do
    resources :dimension_values, path: "values", only: %i[new create edit update]
  end

  get "banking", to: "banking#index", as: :banking
  scope "banking/:account_id", controller: :banking, as: :banking do
    get "", action: :show, as: :account
    post :import
    post :match_suggestions
  end
  resources :bank_statement_lines, only: [] do
    member do
      post :match
      post :unmatch
      post :create_entry
    end
  end

  resources :allocations, only: :create do
    collection { post :oldest_first }
    member { post :reverse }
  end

  resources :entries do
    member do
      post :post
      post :reverse
    end
  end
end
