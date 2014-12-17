class PostsController < ApplicationController
  before_action :authenticate_user!, except: [:feed, :show]
  before_action :correct_user,   only: [:update, :destroy]

#  after_action :verify_authorized

  def new
    @post = current_user.posts.build
  end

  def create
    @post = current_user.posts.build(post_params)
    if @post.save
      flash[:notice] = "Post created!"
      redirect_to @post
    else
      flash[:alert] = "Sorry, couldn't create post. Try again?"
      render 'posts/new'
    end
  end

  def show
    @post = Post.find(params[:id])
    unless @post.user == current_user || @post.user.admin?
      unless @post.publish == true && @post.user.real_name == true
        flash[:alert] = "Sorry, that post isn't viewable."
        redirect_to feed_path
      end
    end
  end

  def update
    @post = Post.find(params[:id])
    if params[:commit] == 'Cancel unsaved changes'
        flash[:notice] = "Unsaved changes cancelled."
        redirect_to @post and return
    elsif @post.update_attributes(post_params)
      if params[:commit] == 'Save & edit more' || params[:commit] == 'Save & edit formatted'
        flash[:notice] = "Post saved."
        redirect_to edit_post_path(@post) and return
      elsif params[:commit] == 'Save & edit html'
        flash[:notice] = "Post saved."
        redirect_to edit_html_path(@post) and return
      else
        flash[:notice] = "Post updated."
      end
    else
      flash[:alert] = "Sorry, couldn't update post. Try again?"
    end
    redirect_to @post
  end

  def edit
    @post = Post.find(params[:id])
  end

  def edit_html
    @post = Post.find(params[:id])
  end

  def destroy
    @post.destroy
    flash[:notice] = "Post deleted"
    redirect_to current_user || root_url
  end

  def feed
    @feed_posts = Post.joins(:user).where(users: {real_name: true}).where(posts: {publish: true}).order('updated_at DESC').paginate(page: params[:page])
  end

  private

    def post_params
      params.require(:post).permit(:title, :content, :publish, :bootsy_image_gallery_id)
    end

    def correct_user
      @post = current_user.posts.find_by(id: params[:id])
      redirect_to root_url if @post.nil?
    end
end
