;; images.lisp -- 2-D Image arrays in Lisp
;; DM/MCFA  08/99

(in-package #:com.ral.image-processing)

;; Image arrays contain flat, row-major, rank 2, arrays of values.
(defclass <image-array> ()
  ((arena :accessor image-array-arena :initarg :arena)))

;; Matrix arrays contain a vector of row vectors of values.
(defclass <matrix-array> ()
  ((rows  :accessor matrix-rows :initarg :rows)))

(defun make-image (arr)
  (if (= (array-rank arr) 2)
      (make-instance '<image-array>
		     :arena arr)
    (error "flat 2-D array required")))

(defun make-matrix (arr)
  (if (and (vectorp arr)
	   (vectorp (aref arr 0)))
      (make-instance '<matrix-array>
		     :rows arr)
    (error "vectors of vectors required")))


; make-similar is supposed to be a low-level interface
; for use when it is already known that the second argument
; is of the correct type.
(defmethod make-similar ((a <image-array>) arr)
  (make-instance '<image-array>
		 :arena arr))

(defmethod make-similar ((m <matrix-array>) vec)
  (make-instance '<matrix-array>
		 :rows vec))

;;
;; pixelwise on image objects
;;
(defmacro pixelwise ((&rest args) body-form &key dest index)
  ;; dest is name of destination variable. If missing or nil then
  ;; a new vector is created for the result.
  ;; "index" is name to use for index so to be accessible in body-form
  (let ((gargs (vm:gensyms-for-args args)))
    (if dest
        (let ((gdst   (gensym))
              (gdstin (gensym)))
          `(let* ((,gdstin ,dest)
                  (,gdst   (image-array-arena ,gdstin))
                  ,@(mapcar #'(lambda (garg arg)
                                `(,garg (image-array-arena ,arg)))
                            gargs args))
             (funcall #'(lambda ,args
                          (vm:elementwise ,args ,body-form
                                          :dest ,gdst
                                          :index ,index))
                      ,@gargs)
             ,gdstin))
      `(make-similar ,(first args)
                     (let ,(mapcar #'(lambda (garg arg)
                                       `(,garg (image-array-arena ,arg)))
                                   gargs args)
                       (funcall #'(lambda ,args
                                    (vm:elementwise ,args ,body-form
                                                    :index ,index))
                                ,@gargs))))
    ))


(defmacro pixelwise-reduce (fn arg &rest keys)
  `(vm:elementwise-reduce ,fn (image-array-arena ,arg) ,@keys))

;; ------------------------------------------------------
;; conversion between the two types of 2-D arrays

(defmethod as-image  ((a <image-array>))
  a)

(defmethod as-image  ((m <matrix-array>))
  (let* ((v     (matrix-rows m))
	 (dimy  (length v))
	 (dimx  (length (aref v 0)))
         (eltyp (array-element-type (aref v 0))))
    (make-image
     (make-array (list dimy dimx)
		 :initial-contents v
                 :element-type eltyp))))


(defmethod as-matrix ((m <matrix-array>))
  m)

(defmethod as-matrix ((a <image-array>))
  (let* ((arr   (image-array-arena a))
         (eltyp (array-element-type arr)))
    (destructuring-bind (dimy dimx) (array-dimensions arr)
      (do ((ix   0 (1+ ix))
	   (offs 0 (+ offs dimx))
	   (mat  (make-array dimy)))
	  ((>= ix dimy) (make-matrix mat))
        (setf (svref mat ix)
              (make-array dimx
                          :displaced-to arr
                          :displaced-index-offset offs
                          :element-type eltyp))
        ))
    ))
	 
;; ----------------------------------------------------
(defclass <subimage-array> (<image-array>)
  ((llc :accessor subimage-llc :initarg :llc)))

(defmethod make-similar ((a <subimage-array>) arr)
  (make-instance '<subimage-array>
		 :arena arr
		 :llc   (subimage-llc a)))

(defmethod subimage-centered ((a <image-array>) ctr ext)
  (subimage a (mapcar #'(lambda (c e)
                          (- c (truncate e 2)))
                      ctr ext)
            ext))

(defun bimod (a b)
  (declare (type fixnum a b))
  (multiple-value-bind (junk rem)
      (truncate a b)
    (declare (ignore junk)
             (type fixnum rem))
    (if (minusp rem)
        (+ rem b)
      rem)))
           
(defun toroidal-coords (coords dims)
  (mapcar #'bimod coords dims))

(defmethod subimage ((a <image-array>) org ext)
  (let* ((arr   (image-array-arena a))
         (eltyp (array-element-type arr))
         (dims  (array-dimensions arr)))
    (destructuring-bind (dimy dimx) dims
      (destructuring-bind (exty extx) ext
        (when (or (> exty dimy)
                  (> extx dimx))
          (error "subimage too large"))
        (destructuring-bind (orgy orgx) (toroidal-coords org dims)
          (let* ((extractor
                  (let ((len1 (min extx (- dimx orgx)))
                        (len2 (- (+ orgx extx) dimx)))
                    (if (plusp len2)
                        #'(lambda (offs)
                            (concatenate 'vector
                                   (make-array len1
                                               :displaced-to arr
                                               :displaced-index-offset offs
                                               :element-type eltyp)
                                   (make-array len2
                                               :displaced-to arr
                                               :displaced-index-offset (- offs orgx)
                                               :element-type eltyp)))
                      #'(lambda (offs)
                          (make-array len1
                                      :displaced-to arr
                                      :displaced-index-offset offs
                                      :element-type eltyp))
                      )))
                 (m
                  (let ((len1 (min (- dimy orgy) exty))
                        (len2 (- (+ orgy exty) dimy))
                        (m    (make-array exty)))
                    (do ((ix 0 (1+ ix))
                         (offs (+ (* orgy dimx) orgx) (+ offs dimx)))
                        ((>= ix len1))
                      (setf (svref m ix) (funcall extractor offs)))
                    (do ((ix 0 (1+ ix))
                         (offs orgx (+ offs dimx)))
                        ((>= ix len2) m)
                      (setf (svref m (+ ix len1)) (funcall extractor offs))))))
            
            (make-instance '<subimage-array>
                           :arena (make-array ext
					      :initial-contents m)
			   :llc   org)
	    )))
      )))

(defmethod subimage ((a <subimage-array>) relorg ext)
  (let ((sub (call-next-method)))
    (setf (subimage-llc sub) (mapcar #'+ (subimage-llc a) relorg))
    sub))

(defmethod place-subimage ((src <image-array>) (dst <image-array>) org)
  (let* ((srcarr (image-array-arena src))
         (srctyp (array-element-type srcarr))
	 (dstarr (image-array-arena dst))
         (dsttyp (array-element-type dstarr)))
    (destructuring-bind (orgy orgx) org
      (destructuring-bind (exty extx) (array-dimensions srcarr)
        (destructuring-bind (dimy dimx) (array-dimensions dstarr)
          (declare (ignore dimy))
          (do ((iy 0 (1+ iy))
	       (dstoff (+ (* orgy dimx) orgx) (+ dstoff dimx))
	       (srcoff 0  (+ srcoff extx)))
	      ((>= iy exty) dst)
	    (map-into (make-array extx
				  :displaced-to dstarr
				  :displaced-index-offset dstoff
                                  :element-type dsttyp)
		      #'identity
		      (make-array extx
				  :displaced-to srcarr
				  :displaced-index-offset srcoff
                                  :element-type srctyp))
	    )))
      )))

(defmethod fill-subimage ((dst <image-array>) k org ext)
  (let* ((dstarr (image-array-arena dst))
         (dsttyp (array-element-type dstarr)))
    (destructuring-bind (orgy orgx) org
      (destructuring-bind (exty extx) ext
        (destructuring-bind (dimy dimx) (array-dimensions dstarr)
          (declare (ignore dimy))
          (do ((iy 0 (1+ iy))
	       (off (+ (* orgy dimx) orgx) (+ off dimx)))
	      ((>= iy exty) dst)
	    (fill (make-array extx
			      :displaced-to dstarr
			      :displaced-index-offset off
                              :element-type dsttyp)
		  k)
	    )))
      )))
	    
			     
(defmethod shift ((m <matrix-array>) dr dc)
  (make-similar
   m
   (vshift (map 'vector
		#'(lambda (v)
		    (vshift v dc))
		(matrix-rows m))
	   dr)))

(defmethod shift ((a <image-array>) dy dx)
  (make-similar
   a
   (vm:shift (image-array-arena a) (list dy dx))))

(defmethod shifth ((a <image-array>))
  (let* ((arr  (image-array-arena a))
         (dims (array-dimensions arr)))
    (apply #'shift a (mapcar #'(lambda (x)
                                 (truncate x 2))
                             dims))))

(defmethod vshift ((v vector) dx)
  (let ((eltyp (array-element-type v)))
    (labels
        ((doshift (dx)
	          (concatenate 'vector
			       (make-array (- (length v) dx)
				           :displaced-to v
				           :displaced-index-offset dx
                                           :element-type eltyp)
			       (make-array dx
				           :displaced-to v
                                           :element-type eltyp))
	          ))
      (cond
       ((zerop dx)  v)
       ((minusp dx) (doshift (- dx)))
       (t           (doshift (- (length v) dx)))
       ))))

(defmethod col-vector ((v vector))
  (make-matrix
   (map 'vector #'vector v)))

(defmethod row-vector ((v vector))
  (make-matrix
   (vector v)))

(defmethod get-row ((m <matrix-array>) r)
  (aref (matrix-rows m) r))

(defmethod get-col ((m <matrix-array>) c)
  (map 'vector #'(lambda (v)
		   (aref v c))
       (matrix-rows m)))

(defmethod get-row-vector ((m <matrix-array>) r)
  (row-vector (get-row m r)))

(defmethod get-col-vector ((m <matrix-array>) c)
  (col-vector (get-col m c)))

(defmethod x-slice ((a <image-array>) y)
  (let* ((arr   (image-array-arena a))
         (eltyp (array-element-type arr))
	 (dimx  (array-dimension arr 1)))
    (make-array dimx
		:displaced-to arr
		:displaced-index-offset (* y dimx)
                :element-type eltyp)
    ))

(defmethod y-slice ((a <image-array>) x)
  (get-col (as-matrix a) x))

(defmethod flipv ((a <image-array>))
  (make-similar a
		(image-array-arena
		 (as-image
		  (make-matrix
		   (reverse (matrix-rows (as-matrix a)))))
		 )))

(defmethod fliph ((a <image-array>))
  (make-similar a
		(image-array-arena
		 (as-image
		  (make-matrix
		   (map 'vector #'reverse
			(matrix-rows (as-matrix a)))))
		 )))

(defmethod transpose ((m <matrix-array>))
  (let* ((arr   (matrix-rows m))
         (eltyp (array-element-type (aref arr 0)))
	 (nx    (length (aref arr 0)))
	 (mt    (make-array nx
                            :element-type eltyp)))
    (dotimes (ix nx (make-similar m mt))
	     (setf (svref mt ix) (map 'vector
				      #'(lambda (v)
					  (aref v ix))
				      arr)))
    ))


(defmethod matrix-diagonal ((m <matrix-array>))
  (let* ((arr   (matrix-rows m))
         (eltyp (array-element-type (aref arr 0)))
	 (ny    (length arr))
	 (vd    (make-array ny
                            :element-type eltyp)))
    (dotimes (iy ny vd)
	     (setf (svref vd iy) (aref (aref arr iy) iy)))
    ))


(defmethod tvscl ((a <image-array>) &rest args)
  (apply #'scigraph:tvscl (image-array-arena a) args))


(defmethod max-ix ((a <image-array>))
  (let* ((arr   (image-array-arena a))
         (eltyp (array-element-type arr))
         (v     (make-array (array-total-size arr)
                            :displaced-to arr
                            :element-type eltyp))
	 (maxv  (reduce #'max v))
         (ix    (position maxv v)))
    (destructuring-bind (dimy dimx) (array-dimensions arr)
      (declare (ignore dimy))
      (multiple-value-list (truncate ix dimx)))
    ))

(defmethod fft ((a <image-array>))
  (make-image (fft:fwd (image-array-arena a))))

(defmethod ifft ((a <image-array>))
  (make-image (fft:inv (image-array-arena a))))

(defun dist (n)
  (make-image (vm:dist n n)))

(defun xplane (n)
  (make-image (vm:xplane n n)))

(defun yplane (n)
  (make-image (vm:yplane n n)))


;; -------------------------------------------------------------

(defmethod where (predicate (a <image-array>))
  (um:where predicate (image-array-arena a)))

(defmethod total ((a <image-array>))
  (pixelwise-reduce #'+ a))

(defmethod mean ((a <image-array>))
  (/ (total a) (array-total-size (image-array-arena a))))


;; --------------------------------------------------------------

(defmethod plot-surface ((a <image-array>)
                         &key
                         zrange
                         (colorfn #'surf:lamps-color-fn))
  (surf:plot-surface (image-array-arena a) :zrange zrange :colorfn colorfn))

(defmethod lego-plot ((a <image-array>) &key zrange)
  (surf:lego-plot (image-array-arena a) :zrange zrange))

#| ;; ... check it out...
(setf img (make-image (scids:getvar)))
(setf simg (subimage-centered img '(43 108) '(21 21)))

(scigraph:window 0)
(plot-surface simg :colorfn #'surf:lamps-color-fn)
(plot-surface simg :colorfn #'surf:gray-color-fn)
(plot-surface simg :colorfn #'surf:red-color-fn)
(plot-surface simg :zrange '(-10 500))

(lego-plot simg)
(lego-plot simg :zrange '(270 600))
(lego-plot simg :zrange '(-100 600))

(plot-surface (shifth (dist 32))
              :colorfn #'surf:lamps-color-fn)
(plot-surface (dist 32)
              :colorfn #'surf:lamps-color-fn)
(lego-plot (dist 32))
(lego-plot (shifth (dist 32)))
|#

(defmethod indices-of ((a <image-array>) row-major-index)
  (multiple-value-list
   (truncate row-major-index
             (array-dimension (image-array-arena a) 1))
   ))

(defmethod find-peak ((a <image-array>))
  (max-ix a))

(defmethod show-peak ((a <image-array>))
  (let* ((pkpos (find-peak a))
         (simg  (subimage-centered a pkpos '(41 41))))
    (lego-plot simg)
    (let ((pcs (vm:standard-percentiles (image-array-arena a))))
      (tvscl a
             :range (list (getf pcs :pc01) (getf pcs :pc99))
             :flipv t)
      (destructuring-bind (y x) pkpos
        (let ((x1 (- x 10))
              (y1 (- y 10))
              (x2 (+ x 10))
              (y2 (+ y 10)))
          (sg:oplot (vector x1 x2 x2 x1 x1) (vector y1 y1 y2 y2 y1)
                    :color sg:$GREEN :thick 2)))
      )))

#|
(show-peak img)
(sg:tvfft (image-array-arena (fft img)) :log t)
(let* ((a     (image-array-arena img))
       (mn    (vm:mean a))
       (stdev (vm:stdev a))
       (pcs   (vm:percentiles a)))
  (multiple-value-call #'sg:log-histo
    (vm:histogram a
                  :range (list (getf pcs :pc01) (getf pcs :pc99))
                  ;; :range (list (- mn (* 3 stdev))
                  ;;              (+ mn (* 3 stdev)))
                  )
    :color sg:$red))
|#
